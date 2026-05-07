# Player Bracket Trends — Design

**Date:** 2026-05-07
**Status:** Approved (pending review)

## Goal

Track per-character per-bracket leaderboard history so the API can expose:

1. **Leaderboard delta badge** — "▲5 +32 rating since last cycle" on each entry.
2. **Profile sparkline** — rating/rank/W-L progression over the last 7 days.

## Non-goals

- Full-season history (>7 days). Out of scope until volume / UX justify.
- Per-cycle event log. Snapshots only — derived state, not event stream.
- Backfilling existing leaderboard data into history. Feature starts producing data on deploy.

## Storage

### Schema

```sql
CREATE TABLE pvp_leaderboard_entry_snapshots (
  id                 BIGSERIAL PRIMARY KEY,
  character_id       BIGINT NOT NULL REFERENCES characters(id),
  pvp_leaderboard_id BIGINT NOT NULL REFERENCES pvp_leaderboards(id),
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

### Volume

- 7-day retention × 4 cycles/day × 100k entries = ~2.8M rows steady-state.
- ~120 B/row including indexes → ~336 MB → ~8.7% of current 3.88 GB DB.
- Acceptable. Re-evaluate when total DB shrinks via other optimizations.

### Why FK to leaderboard, not entry

`PvpLeaderboardEntry` rows are deleted in `SyncLeaderboardService#remove_dropped_entries` when a character drops off the leaderboard. Snapshots must survive that. FK to `pvp_leaderboards` (which is per-season-region-bracket and stable) keeps history intact.

## Write path

Snapshots written inside the existing `SyncLeaderboardService` transaction, after entry upsert, before `remove_dropped_entries`:

```ruby
ActiveRecord::Base.transaction do
  PvpLeaderboardEntry.upsert_all(entry_records, ...)

  snapshot_records = entry_records.map { |r| ... }
  PvpLeaderboardEntrySnapshot.insert_all(snapshot_records, on_duplicate: :skip)

  leaderboard.update!(last_synced_at: snapshot_at)
  remove_dropped_entries(leaderboard.id, character_ids)
end
```

`on_duplicate: :skip` makes the insert idempotent under `with_deadlock_retry` re-runs.

### Deadlock analysis

| Scenario | Verdict |
|---|---|
| Two parallel brackets writing snapshots for overlapping chars | Different `pvp_leaderboard_id` → no unique index conflict. Safe. |
| Snapshot insert FK lock vs concurrent character UPDATE | PG 9.3+ uses `FOR KEY SHARE` for FK; character UPDATEs touch non-key columns → `FOR NO KEY UPDATE`. These don't conflict. Safe. |
| Lock-hold time growth | ~50% longer (one extra `insert_all` of ~2500 rows). Other brackets wait on their own row, not this one. Acceptable. |
| Idempotency under retry | `on_duplicate: :skip` avoids unique-violation on re-run. Safe. |

No new deadlock paths. Existing `with_deadlock_retry` (5 attempts) handles transient.

## Read path

### Leaderboard delta

`GET /api/v1/pvp/:season/:region/leaderboards/:bracket` — extend response.

Single CTE query keyed off `(pvp_leaderboard_id, snapshot_at DESC)` index:

```sql
WITH ranked AS (
  SELECT character_id, rank, rating, wins, losses,
         ROW_NUMBER() OVER (PARTITION BY character_id ORDER BY snapshot_at DESC) AS rn
  FROM pvp_leaderboard_entry_snapshots
  WHERE pvp_leaderboard_id = :leaderboard_id
)
SELECT character_id, rank, rating, wins, losses
FROM ranked WHERE rn = 2
```

Result hashed by `character_id`, merged into entry response as `delta: { rank, rating, wins, losses }`. `delta` is `null` when no prior snapshot exists.

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

## First-cycle behavior

- No backfill needed. Feature degrades gracefully from day 0.
- After 1 cycle: history exists, no delta yet.
- After 2 cycles (~12h): leaderboard badges start populating.
- After 28 cycles (~7d): full sparkline depth.

Frontend handling:

- Badge: hide if `delta` is `null`.
- Sparkline: render single point or "not enough data" if <3 points.

## Edge cases

| Case | Behavior |
|---|---|
| Char drops off, returns later | Sparkline gap. Delta compares to last on-leaderboard snapshot (could be hours/days old). |
| Cycle aborted mid-sync | Some leaderboards have new snapshots, others don't. No corruption — snapshots are leaderboard-local. |
| Manual `SyncBracketJob` re-sync | New `snapshot_at` → new snapshot row. Sparkline gets denser cluster. Acceptable. |
| Shuffle dedup | `SyncLeaderboardService` dedupes by `character_id` (best rank kept) before insert. Snapshots inherit dedup. |
| Concurrent same-bracket sync | `leaderboard.with_lock` serializes. No dup snapshots. |
| Char has no entries this cycle | No snapshot written. Sparkline shows last + gap. |

## Test plan

- **Model:** `spec/models/pvp_leaderboard_entry_snapshot_spec.rb` — associations, unique constraint.
- **Service:** extend `spec/services/pvp/leaderboards/sync_leaderboard_service_spec.rb` — snapshots created with matching `snapshot_at`; idempotent under retry; survives entry deletion.
- **Controllers:**
  - `spec/requests/api/v1/pvp/leaderboards_spec.rb` — delta field present when prior snapshot exists, null otherwise.
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

- `app/services/pvp/leaderboards/sync_leaderboard_service.rb` — insert snapshots in txn.
- `app/controllers/api/v1/pvp/leaderboards_controller.rb` — merge deltas into entry response.
- `app/serializers/...` — add `delta` field to leaderboard entry serializer.
- `config/routes.rb` — add `/api/v1/characters/:region/:realm/:name/trends`.
- `config/recurring.yml` — add prune job.
- `sig/` — RBS updates for new model + query class.

## Out of scope (future)

- Trends UI on frontend (`bis-web/`). This spec ships API only.
- Pre-aggregated rolling stats (avg rating, peak rating). Compute on read for now.
- WebSocket push of delta on cycle complete. REST polling sufficient at current cadence.

## Open questions

None — locked in Q&A.
