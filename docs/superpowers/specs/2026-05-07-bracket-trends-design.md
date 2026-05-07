# Player Bracket Trends — Design

**Date:** 2026-05-07
**Status:** Approved (pending review)

## Goal

Track per-character per-bracket leaderboard history so the API can expose:

1. **Leaderboard delta badge** — "▲5 +32 rating in last 24h" on each entry. Inline on existing leaderboard endpoint.
2. **Profile sparkline** — rating/rank/W-L progression over the last 7 days. Separate endpoint, fetched on-demand from profile view.

## Non-goals

- Full-season history (>7 days). Out of scope until volume / UX justify.
- 14d / 30d sparkline tiers. Future addition via daily-rollup table; not part of v1.
- Per-cycle event log. Snapshots only — derived state, not event stream.
- Backfilling existing leaderboard data into history. Feature starts producing data on deploy.
- Sparkline payload bundled into leaderboard response. Considered, rejected — 2500 entries × 28 points ≈ 2 MB per leaderboard response, mostly wasted (users only view top rows). Sparkline lives on its own endpoint.

## Storage

### Schema

```sql
CREATE TABLE pvp_leaderboard_entry_snapshots (
  id                 BIGSERIAL PRIMARY KEY,
  character_id       BIGINT NOT NULL REFERENCES characters(id),
  pvp_leaderboard_id BIGINT NOT NULL REFERENCES pvp_leaderboards(id),
  pvp_sync_cycle_id  BIGINT NULL REFERENCES pvp_sync_cycles(id),
  snapshot_at        TIMESTAMPTZ NOT NULL,
  rank               INTEGER NOT NULL,
  rating             INTEGER NOT NULL,
  wins               INTEGER NOT NULL,
  losses             INTEGER NOT NULL,
  spec_id            INTEGER NULL
);

CREATE UNIQUE INDEX idx_snap_unique
  ON pvp_leaderboard_entry_snapshots (character_id, pvp_leaderboard_id, snapshot_at);

CREATE INDEX idx_snap_leaderboard_time
  ON pvp_leaderboard_entry_snapshots (pvp_leaderboard_id, snapshot_at DESC);

CREATE INDEX idx_snap_character_time
  ON pvp_leaderboard_entry_snapshots (character_id, snapshot_at DESC);
```

`pvp_sync_cycle_id` is `NULL` for backfilled rows and ad-hoc syncs (`SyncBracketJob`); populated when a sync cycle context exists. Used for traceability and retroactive cleanup. Not indexed — ad-hoc lookups only.

`spec_id` is denormalized from the entry. Redundant with `pvp_leaderboards.bracket` for shuffle/blitz (bracket name encodes spec) but cheap (4 B/row, ~11 MB total at saturation) and useful for 2v2/3v3 sparklines that want to label by the spec the char was running.

### Volume

- 7-day retention × 4 cycles/day × 100k entries = ~2.8M rows steady-state.
- ~128 B/row including indexes (with `pvp_sync_cycle_id` + `spec_id`) → ~360 MB → ~9% of current 3.88 GB DB.
- Acceptable. Re-evaluate when total DB shrinks via other optimizations.

### Why FK to leaderboard, not entry

`PvpLeaderboardEntry` rows are deleted in `SyncLeaderboardService#remove_dropped_entries` when a character drops off the leaderboard. Snapshots must survive that. FK to `pvp_leaderboards` (which is per-season-region-bracket and stable) keeps history intact.

## Write path

Snapshots are derived data — primary leaderboard entries must not be lost over a snapshot bug. Snapshot insert lives in a **separate, isolated block** after the entry-upsert transaction commits. Failures are logged + sent to Sentry, not propagated.

```ruby
ActiveRecord::Base.transaction do
  PvpLeaderboardEntry.upsert_all(entry_records, ...)
  leaderboard.update!(last_synced_at: snapshot_at)
  remove_dropped_entries(leaderboard.id, character_ids)
end

# Snapshots: best-effort, isolated from primary writes
begin
  snapshot_records = entry_records.map { |r| build_snapshot(r, sync_cycle_id) }
  inserted = PvpLeaderboardEntrySnapshot.insert_all(snapshot_records, on_duplicate: :skip)
  Pvp::SyncLogger.snapshots_inserted(count: inserted.rows.size, leaderboard: leaderboard)
rescue => e
  Rails.logger.error("[SyncLeaderboardService] Snapshot insert failed: #{e.message}")
  Sentry.capture_exception(e, extra: {
    service: "SyncLeaderboardService",
    leaderboard_id: leaderboard.id,
    snapshot_at: snapshot_at
  })
end
```

`on_duplicate: :skip` makes the insert idempotent if `SyncLeaderboardService` is re-invoked for the same `snapshot_at` (e.g., manual replay).

`SyncLogger.snapshots_inserted` is a new helper logging count per leaderboard — surfaces silent breakage (zero inserts when nonzero expected).

### Deadlock analysis

Since snapshot insert lives outside the primary txn:

| Scenario | Verdict |
|---|---|
| Two parallel brackets writing snapshots for overlapping chars | Different `pvp_leaderboard_id` → no unique index conflict. Safe. |
| Snapshot insert FK lock vs concurrent character UPDATE | PG 9.3+ uses `FOR KEY SHARE` for FK; character UPDATEs touch non-key columns → `FOR NO KEY UPDATE`. These don't conflict. Safe. |
| Snapshot insert blocks primary writes | Out of primary txn — primary `with_lock` already released. Zero blocking on entry path. |
| Idempotency under retry | `on_duplicate: :skip` avoids unique-violation on manual replay. Safe. |

No new deadlock paths.

## Read path

### Leaderboard delta (24h)

`GET /api/v1/pvp/:season/:region/leaderboards/:bracket` — extend response.

Single query keyed off `(pvp_leaderboard_id, snapshot_at DESC)` index. For each char on the leaderboard, find the most-recent snapshot at-or-before 24h ago, capped at 48h to avoid stale baselines:

```sql
SELECT DISTINCT ON (character_id)
  character_id, rank, rating, wins, losses, snapshot_at
FROM pvp_leaderboard_entry_snapshots
WHERE pvp_leaderboard_id = :leaderboard_id
  AND snapshot_at <= NOW() - INTERVAL '24 hours'
  AND snapshot_at >= NOW() - INTERVAL '48 hours'
ORDER BY character_id, snapshot_at DESC
```

Result hashed by `character_id`, merged into entry response as `delta: { rank, rating, wins, losses }`. `delta` is `null` when no snapshot in the 24-48h window (char is new, was inactive, or first 24h post-deploy).

Payload addition: ~16 B/entry × 2500 entries ≈ ~40 KB extra per response. Acceptable.

### Profile trends

`GET /api/v1/characters/:region/:realm/:name/trends` — new endpoint.

```sql
SELECT pl.bracket, pl.region, s.snapshot_at, s.rank, s.rating, s.wins, s.losses, s.spec_id
FROM pvp_leaderboard_entry_snapshots s
JOIN pvp_leaderboards pl ON pl.id = s.pvp_leaderboard_id
WHERE s.character_id = :char_id
  AND s.snapshot_at >= NOW() - INTERVAL '7 days'
ORDER BY pl.bracket, s.snapshot_at ASC
```

Response:

```json
{
  "character": { "name": "...", "realm": "...", "region": "..." },
  "trends": [
    {
      "bracket": "3v3",
      "snapshots": [
        { "at": "2026-05-07T06:00:00Z", "rank": 5, "rating": 2810, "wins": 42, "losses": 18 },
        ...
      ]
    },
    {
      "bracket": "shuffle-rogue-assassination",
      "snapshots": [...]
    }
  ]
}
```

Index `(character_id, snapshot_at DESC)` covers this.

### Caching

- Leaderboard endpoint: existing `meta_cache_fetch` (30 min) + CDN. Delta computed once per cycle.
- Trends endpoint: cache `(char_id, season_id)`, 5 min TTL. Invalidates naturally on next cycle.

## Pruning

Daily recurring job at 03:00 UTC. Batched delete (10k rows/batch, no extra index needed).

```ruby
module Pvp
  class PruneLeaderboardSnapshotsJob < ApplicationJob
    queue_as :default
    RETENTION = 7.days

    def perform
      cutoff = RETENTION.ago
      total = 0
      loop do
        n = PvpLeaderboardEntrySnapshot.where("snapshot_at < ?", cutoff).limit(10_000).delete_all
        total += n
        break if n.zero?
      end
      Rails.logger.info("[PruneLeaderboardSnapshotsJob] Deleted #{total} rows")
    end
  end
end
```

`config/recurring.yml`:

```yaml
prune_leaderboard_snapshots:
  class: Pvp::PruneLeaderboardSnapshotsJob
  schedule: every day at 3am UTC
```

## Day-0 backfill

Migration runs a one-shot backfill from current `pvp_leaderboard_entries` so the very first cycle after deploy already has a baseline (saves 6h of empty state):

```sql
INSERT INTO pvp_leaderboard_entry_snapshots
  (character_id, pvp_leaderboard_id, pvp_sync_cycle_id, snapshot_at,
   rank, rating, wins, losses, spec_id, created_at, updated_at)
SELECT
  e.character_id, e.pvp_leaderboard_id, NULL, e.snapshot_at,
  e.rank, e.rating, e.wins, e.losses, e.spec_id, NOW(), NOW()
FROM pvp_leaderboard_entries e
ON CONFLICT (character_id, pvp_leaderboard_id, snapshot_at) DO NOTHING;
```

~100k rows, runs in <2s. `pvp_sync_cycle_id` is NULL since these snapshots predate cycle tracking.

## Post-deploy timeline

- After backfill: 1 snapshot per entry, all at the same `snapshot_at`.
- After 1 cycle (~6h): second snapshot per entry, but still <24h old → no delta yet.
- After ~24h (~4 cycles): 24h-baseline available, leaderboard badges populate.
- After ~7d (~28 cycles): full sparkline depth on profile endpoint.

Frontend handling:

- Badge: hide if `delta` is `null`.
- Sparkline: render single point or "not enough data" if <3 points.

## Edge cases

| Case | Behavior |
|---|---|
| Char drops off, returns later | Sparkline gap. Delta is `null` if no snapshot in 24-48h window; otherwise compared to oldest qualifying snapshot. |
| Char on leaderboard <24h | `delta: null` — too new for 24h baseline. |
| Char inactive >48h | `delta: null` — baseline too stale to compare. |
| Cycle aborted mid-sync | Some leaderboards have new snapshots, others don't. No corruption — snapshots are leaderboard-local. |
| Manual `SyncBracketJob` re-sync | New `snapshot_at` → new snapshot row. Sparkline gets denser cluster. Acceptable. |
| Shuffle dedup | `SyncLeaderboardService` dedupes by `character_id` (best rank kept) before insert. Snapshots inherit dedup. |
| Concurrent same-bracket sync | `leaderboard.with_lock` serializes. No dup snapshots. |
| Char has no entries this cycle | No snapshot written. Sparkline shows last + gap. |

## Test plan

- **Model:** `spec/models/pvp_leaderboard_entry_snapshot_spec.rb` — associations, unique constraint.
- **Service:** extend `spec/services/pvp/leaderboards/sync_leaderboard_service_spec.rb` — snapshots created with matching `snapshot_at`; idempotent under retry; survives entry deletion.
- **Query:** `spec/services/pvp/leaderboards/leaderboard_deltas_query_spec.rb` — picks snapshot in 24-48h window; null when out of window or absent.
- **Controllers:**
  - `spec/requests/api/v1/pvp/leaderboards_spec.rb` — delta field present when 24h baseline exists, null otherwise.
  - `spec/requests/api/v1/characters/trends_spec.rb` — arrays per bracket, 7d window enforced, cache key respected.
- **Job:** `spec/jobs/pvp/prune_leaderboard_snapshots_job_spec.rb` — deletes only past cutoff, batches correctly.

## File touches

### New

- `db/migrate/<ts>_create_pvp_leaderboard_entry_snapshots.rb`
- `app/models/pvp_leaderboard_entry_snapshot.rb`
- `spec/models/pvp_leaderboard_entry_snapshot_spec.rb`
- `spec/factories/pvp_leaderboard_entry_snapshots.rb`
- `app/jobs/pvp/prune_leaderboard_snapshots_job.rb`
- `spec/jobs/pvp/prune_leaderboard_snapshots_job_spec.rb`
- `app/controllers/api/v1/characters/trends_controller.rb`
- `spec/requests/api/v1/characters/trends_spec.rb`
- `app/services/pvp/leaderboards/leaderboard_deltas_query.rb` — CTE-based delta lookup, returns Hash keyed by `character_id`.

### Edited

- `app/services/pvp/leaderboards/sync_leaderboard_service.rb` — insert snapshots in isolated rescue block; pass `sync_cycle_id` from caller.
- `app/jobs/pvp/sync_current_season_leaderboards_job.rb` — pass `sync_cycle_id` into `SyncLeaderboardService`.
- `app/controllers/api/v1/pvp/leaderboards_controller.rb` — merge deltas into entry response.
- `app/serializers/...` — add `delta` field to leaderboard entry serializer.
- `app/lib/pvp/sync_logger.rb` — add `snapshots_inserted` class method.
- `config/routes.rb` — add `/api/v1/characters/:region/:realm/:name/trends`.
- `config/recurring.yml` — add prune job.
- `sig/` — RBS updates for new model + query class.

## Out of scope (future)

- Trends UI on frontend (`bis-web/`). This spec ships API only.
- Pre-aggregated rolling stats (avg rating, peak rating). Compute on read for now.
- WebSocket push of delta on cycle complete. REST polling sufficient at current cadence.

## Open questions

None — locked in Q&A.
