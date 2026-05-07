# Talent Sync Refactor — Design Spec

**Date:** 2026-04-28
**Status:** Approved

---

## Context

`pvp:sync_talents` takes 7 minutes. Root cause: `SyncTreeService#fetch_missing_media` runs a
sequential HTTP loop over ~600 talents (2–3 Blizzard/WoWHead calls each = ~1,500 HTTP calls).
The tree structure sync itself (~14 Blizzard API calls) finishes in under a minute.

Additionally, `Talent.talent_type` drifts silently: `insert_all` on conflict does nothing, so a
talent inserted as `"class"` stays `"class"` forever even when Blizzard later classifies it as
`"hero"`. This corrupts the rendered talent tree (Halo showing in class section instead of hero).

---

## Goals

1. **Speed:** `pvp:sync_talents` completes in ~1 min (structure only). Media fills async.
2. **Correctness:** `talent_type` self-heals on every sync. Hero always wins over class/spec.
3. **Reliability:** Media job is idempotent, retriable, and doesn't block aggregation.

---

## Architecture

### Split into two services

**`SyncTreeService`** (existing, trimmed)
- Keeps: structure sync (positions, prereqs, spec assignments, talent_type correction)
- Removes: `fetch_missing_media`, `sync_talent_media`, `sync_pvp_talent_media`, `sync_icon`, `sync_icon_from_wowhead`, `fetch_spell_icon_url`, `fetch_talent_data`, `fetch_wowhead_tooltip`, `media_incomplete_scope`, `save_name`, `save_description`
- After structure sync succeeds: enqueue `SyncTalentMediaJob.perform_later`

**`SyncTalentMediaService`** (new, ~100 lines)
- File: `app/services/blizzard/data/talents/sync_talent_media_service.rb`
- Moves all media-fetch methods from `SyncTreeService`
- Uses `run_with_threads` (already on `ApplicationJob`) via the job wrapper
- Processes talents in parallel (concurrency: 10, capped to DB pool headroom)
- Idempotent: only fetches talents where `icon_url IS NULL` or description missing

**`SyncTalentMediaJob`** (new, ~20 lines)
- File: `app/jobs/sync_talent_media_job.rb`
- Wraps `SyncTalentMediaService`
- Calls `run_with_threads` on the incomplete scope
- `retry_on Blizzard::Client::Error, wait: :polynomially_longer, attempts: 3`

### Fix `talent_type` priority

In `process_nodes`: hero must not be overwritten by a later class/spec entry for the same `blizzard_id`.

```ruby
# Only upgrade to higher-priority type; never downgrade
TALENT_TYPE_PRIORITY = { "class" => 0, "spec" => 1, "hero" => 2 }.freeze

talents_from_node(node).each do |blizzard_id, spell_id, name|
  existing = talent_attrs[blizzard_id]
  if existing.nil? || TALENT_TYPE_PRIORITY[talent_type] > TALENT_TYPE_PRIORITY[existing[:talent_type].to_s]
    talent_attrs[blizzard_id] = { ..., talent_type: talent_type }
  end
end
```

`apply_talent_types` (already added) bulk-corrects DB on every sync — so prod self-heals after next `pvp:sync_talents`.

---

## Data Flow

```
pvp:sync_talents / SyncTalentTreesJob
  └─ SyncTreeService#call (~1 min)
       ├─ fetch 14 Blizzard tree endpoints
       ├─ apply_positions (bulk UPDATE)
       ├─ apply_prerequisites (DELETE + INSERT_ALL)
       ├─ apply_talent_types (bulk UPDATE — fixes drift)
       ├─ apply_spec_assignments (upsert per spec)
       ├─ save_names_from_tree (batch translations)
       └─ SyncTalentMediaJob.perform_later ──► queue

SyncTalentMediaJob (async, ~5 min, non-blocking)
  └─ SyncTalentMediaService#call
       └─ run_with_threads(incomplete_talents, concurrency: 10)
            └─ per talent: talent endpoint → pvp fallback → wowhead fallback → update icon_url + description
```

---

## Files

| Action | File |
|--------|------|
| Modify | `app/services/blizzard/data/talents/sync_tree_service.rb` |
| Create | `app/services/blizzard/data/talents/sync_talent_media_service.rb` |
| Create | `app/jobs/sync_talent_media_job.rb` |
| Modify | `app/jobs/sync_talent_trees_job.rb` (add retry_on) |

---

## Error Handling

- Structure sync fails → `SyncTalentMediaJob` is NOT enqueued (no media job on broken tree)
- Media job fails per-talent → log warning, skip talent, continue (same as today)
- Media job fails entirely → retried up to 3× with exponential backoff

---

## Testing

```bash
# Simulate talent_type drift and verify self-heal
bundle exec rails runner "Talent.find_by(blizzard_id: 122312).update_columns(talent_type: 'class')"
bundle exec rails runner "Blizzard::Data::Talents::SyncTreeService.call; puts Talent.find_by(blizzard_id: 122312).talent_type"
# Expected: "hero"

# Verify media job enqueues after structure sync
bundle exec rspec spec/services/blizzard/data/talents/sync_tree_service_spec.rb

# Time the structure-only sync
time bundle exec rails runner "Blizzard::Data::Talents::SyncTreeService.call"
# Expected: < 90 seconds
```

---

## Out of Scope

- Parallelising the 14 `fetch_tree` Blizzard API calls (already fast enough)
- Adding a "media_sync_attempted_at" column to skip permanently-missing icons (future)
- Cron scheduling for media job (trigger on-demand for now)
