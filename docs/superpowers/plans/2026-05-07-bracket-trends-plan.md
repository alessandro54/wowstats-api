# Player Bracket Trends Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship per-character per-bracket leaderboard history backing 24h delta badges on the existing leaderboard endpoint and 7-day sparklines on a new character trends endpoint.

**Architecture:** New `pvp_leaderboard_entry_snapshots` table written by `SyncLeaderboardService` (in an isolated rescue block, after the primary entry-upsert transaction commits). Day-0 backfill seeded inline in the create migration. Read paths: `LeaderboardDeltasQuery` (CTE-based DISTINCT ON over 24-48h window) merged into existing leaderboard response; new `Api::V1::Characters::TrendsController` returns per-bracket sparklines for the last 7 days. Daily prune job keeps the table at ~2.8M rows / ~360 MB.

**Tech Stack:** Rails 8.1, PostgreSQL (multi-database, primary), RSpec, FactoryBot, Steep + RBS, SolidQueue.

**Spec:** `docs/superpowers/specs/2026-05-07-bracket-trends-design.md`

---

## File Structure

### New files

| Path | Purpose |
|---|---|
| `db/migrate/<ts>_create_pvp_leaderboard_entry_snapshots.rb` | Create table + indexes + day-0 backfill |
| `app/models/pvp_leaderboard_entry_snapshot.rb` | AR model |
| `spec/models/pvp_leaderboard_entry_snapshot_spec.rb` | Model spec |
| `spec/factories/pvp_leaderboard_entry_snapshots.rb` | Factory |
| `app/services/pvp/leaderboards/leaderboard_deltas_query.rb` | CTE query — 24h baseline lookup |
| `spec/services/pvp/leaderboards/leaderboard_deltas_query_spec.rb` | Query spec |
| `app/serializers/pvp/leaderboard_entry_serializer.rb` | Per-entry serializer w/ optional `delta` |
| `app/controllers/api/v1/characters/trends_controller.rb` | Profile sparkline endpoint |
| `spec/requests/api/v1/characters/trends_spec.rb` | Request spec |
| `app/jobs/pvp/prune_leaderboard_snapshots_job.rb` | Recurring 7-day prune |
| `spec/jobs/pvp/prune_leaderboard_snapshots_job_spec.rb` | Job spec |

### Modified files

| Path | Change |
|---|---|
| `app/services/pvp/leaderboards/sync_leaderboard_service.rb` | Add isolated snapshot insert block, accept `sync_cycle_id:` kwarg |
| `spec/services/pvp/leaderboards/sync_leaderboard_service_spec.rb` | Cover snapshot inserts + isolation |
| `app/jobs/pvp/sync_current_season_leaderboards_job.rb` | Pass `sync_cycle_id` into `SyncLeaderboardService.call` |
| `app/lib/pvp/sync_logger.rb` | Add `.snapshots_inserted` class method |
| `app/controllers/api/v1/pvp/leaderboards_controller.rb` | Render via serializer + merge deltas |
| `spec/requests/api/v1/pvp/leaderboards_spec.rb` | Add delta-field expectations |
| `config/routes.rb` | New route `/characters/:region/:realm/:name/trends` |
| `config/recurring.yml` | Schedule prune job |
| `sig/pvp/leaderboards/sync_leaderboard_service.rbs` | Signature update |

---

## Task 1: Create snapshots table + day-0 backfill

**Files:**
- Create: `db/migrate/<ts>_create_pvp_leaderboard_entry_snapshots.rb`

- [ ] **Step 1: Generate migration**

```bash
bundle exec rails g migration CreatePvpLeaderboardEntrySnapshots
```

Note the generated timestamp filename. Use it for the rest of this task.

- [ ] **Step 2: Write migration body**

Replace the generated file content with:

```ruby
class CreatePvpLeaderboardEntrySnapshots < ActiveRecord::Migration[8.1]
  def up
    create_table :pvp_leaderboard_entry_snapshots do |t|
      t.references :character,         null: false, foreign_key: true
      t.references :pvp_leaderboard,   null: false, foreign_key: true
      t.references :pvp_sync_cycle,    null: true,  foreign_key: true
      t.datetime   :snapshot_at,       null: false
      t.integer    :rank,              null: false
      t.integer    :rating,            null: false
      t.integer    :wins,              null: false
      t.integer    :losses,            null: false
      t.integer    :spec_id
      t.timestamps
    end

    add_index :pvp_leaderboard_entry_snapshots,
              %i[character_id pvp_leaderboard_id snapshot_at],
              unique: true,
              name:   :idx_snap_unique

    add_index :pvp_leaderboard_entry_snapshots,
              %i[pvp_leaderboard_id snapshot_at],
              order: { snapshot_at: :desc },
              name:  :idx_snap_leaderboard_time

    add_index :pvp_leaderboard_entry_snapshots,
              %i[character_id snapshot_at],
              order: { snapshot_at: :desc },
              name:  :idx_snap_character_time

    # Day-0 backfill from current entries so the first post-deploy cycle
    # already has a baseline (saves ~6h of empty-state UX).
    execute <<~SQL
      INSERT INTO pvp_leaderboard_entry_snapshots
        (character_id, pvp_leaderboard_id, pvp_sync_cycle_id, snapshot_at,
         rank, rating, wins, losses, spec_id, created_at, updated_at)
      SELECT
        e.character_id, e.pvp_leaderboard_id, NULL, e.snapshot_at,
        e.rank, e.rating, e.wins, e.losses, e.spec_id, NOW(), NOW()
      FROM pvp_leaderboard_entries e
      ON CONFLICT (character_id, pvp_leaderboard_id, snapshot_at) DO NOTHING;
    SQL
  end

  def down
    drop_table :pvp_leaderboard_entry_snapshots
  end
end
```

- [ ] **Step 3: Run migration**

```bash
bundle exec rails db:migrate
```

Expected: `CreatePvpLeaderboardEntrySnapshots: migrated`. The model annotator may also touch annotated files — that's fine.

- [ ] **Step 4: Verify table + backfilled rows**

```bash
bundle exec rails runner 'puts PvpLeaderboardEntrySnapshot.count'
```

Expected: a count roughly equal to `PvpLeaderboardEntry.count` (the backfill is idempotent via `ON CONFLICT DO NOTHING`).

If `PvpLeaderboardEntrySnapshot` constant errors, the model class doesn't exist yet (created in Task 2). Fall back to:

```bash
bundle exec rails runner 'puts ApplicationRecord.connection.select_value("SELECT COUNT(*) FROM pvp_leaderboard_entry_snapshots")'
```

- [ ] **Step 5: Commit**

```bash
git add db/migrate db/schema.rb
git commit -m "feat(db): create pvp_leaderboard_entry_snapshots with day-0 backfill"
```

---

## Task 2: Model + factory

**Files:**
- Create: `app/models/pvp_leaderboard_entry_snapshot.rb`
- Create: `spec/factories/pvp_leaderboard_entry_snapshots.rb`
- Create: `spec/models/pvp_leaderboard_entry_snapshot_spec.rb`

- [ ] **Step 1: Write the failing model spec**

```ruby
require "rails_helper"

RSpec.describe PvpLeaderboardEntrySnapshot, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:character) }
    it { is_expected.to belong_to(:pvp_leaderboard) }
    it { is_expected.to belong_to(:pvp_sync_cycle).optional }
  end

  describe "validations" do
    subject { build(:pvp_leaderboard_entry_snapshot) }

    it { is_expected.to validate_presence_of(:snapshot_at) }
    it { is_expected.to validate_presence_of(:rank) }
    it { is_expected.to validate_presence_of(:rating) }
    it { is_expected.to validate_presence_of(:wins) }
    it { is_expected.to validate_presence_of(:losses) }
  end

  describe "uniqueness" do
    it "rejects duplicate (character, leaderboard, snapshot_at)" do
      existing = create(:pvp_leaderboard_entry_snapshot)
      dup = build(
        :pvp_leaderboard_entry_snapshot,
        character:       existing.character,
        pvp_leaderboard: existing.pvp_leaderboard,
        snapshot_at:     existing.snapshot_at
      )
      expect { dup.save!(validate: false) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end
  end
end
```

- [ ] **Step 2: Run spec to verify it fails**

```bash
bundle exec rspec spec/models/pvp_leaderboard_entry_snapshot_spec.rb
```

Expected: FAIL — uninitialized constant `PvpLeaderboardEntrySnapshot`.

- [ ] **Step 3: Write factory**

```ruby
# spec/factories/pvp_leaderboard_entry_snapshots.rb
FactoryBot.define do
  factory :pvp_leaderboard_entry_snapshot do
    association :character
    association :pvp_leaderboard
    pvp_sync_cycle { nil }
    snapshot_at    { Time.current }
    rank           { 1 }
    rating         { 2400 }
    wins           { 50 }
    losses         { 20 }
    spec_id        { nil }
  end
end
```

- [ ] **Step 4: Write model**

```ruby
# app/models/pvp_leaderboard_entry_snapshot.rb
class PvpLeaderboardEntrySnapshot < ApplicationRecord
  belongs_to :character
  belongs_to :pvp_leaderboard
  belongs_to :pvp_sync_cycle, optional: true

  validates :snapshot_at, :rank, :rating, :wins, :losses, presence: true
end
```

- [ ] **Step 5: Run spec to verify it passes**

```bash
bundle exec rspec spec/models/pvp_leaderboard_entry_snapshot_spec.rb
```

Expected: PASS, all examples green.

- [ ] **Step 6: Commit**

```bash
git add app/models/pvp_leaderboard_entry_snapshot.rb spec/models/pvp_leaderboard_entry_snapshot_spec.rb spec/factories/pvp_leaderboard_entry_snapshots.rb
git commit -m "feat(model): add PvpLeaderboardEntrySnapshot"
```

---

## Task 3: SyncLogger.snapshots_inserted helper

**Files:**
- Modify: `app/lib/pvp/sync_logger.rb`
- Modify: `spec/lib/pvp/sync_logger_spec.rb` (create if missing)

- [ ] **Step 1: Write the failing spec**

If `spec/lib/pvp/sync_logger_spec.rb` does not exist, create it with the full file body:

```ruby
require "rails_helper"

RSpec.describe Pvp::SyncLogger do
  describe ".snapshots_inserted" do
    let(:leaderboard) { create(:pvp_leaderboard) }

    it "logs the snapshot count and leaderboard label" do
      expect(Rails.logger).to receive(:info).with(/snapshots inserted=42/i)
      described_class.snapshots_inserted(count: 42, leaderboard: leaderboard)
    end
  end
end
```

If the file already exists, append the `describe ".snapshots_inserted"` block inside `RSpec.describe Pvp::SyncLogger do ... end`.

- [ ] **Step 2: Run spec to verify it fails**

```bash
bundle exec rspec spec/lib/pvp/sync_logger_spec.rb
```

Expected: FAIL — `NoMethodError: undefined method 'snapshots_inserted'`.

- [ ] **Step 3: Add helper to SyncLogger**

Open `app/lib/pvp/sync_logger.rb`. Find the existing `def self.batch_complete(outcome:)` declaration. Add this method directly above it:

```ruby
def self.snapshots_inserted(count:, leaderboard:)
  logger.info(
    "  [snapshot] #{leaderboard.region}/#{leaderboard.bracket}: snapshots inserted=#{count}"
  )
end
```

- [ ] **Step 4: Run spec to verify it passes**

```bash
bundle exec rspec spec/lib/pvp/sync_logger_spec.rb
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/pvp/sync_logger.rb spec/lib/pvp/sync_logger_spec.rb
git commit -m "feat(logger): add Pvp::SyncLogger.snapshots_inserted"
```

---

## Task 4: SyncLeaderboardService writes snapshots

**Files:**
- Modify: `app/services/pvp/leaderboards/sync_leaderboard_service.rb`
- Modify: `spec/services/pvp/leaderboards/sync_leaderboard_service_spec.rb`

- [ ] **Step 1: Write failing tests for snapshot insertion**

Open `spec/services/pvp/leaderboards/sync_leaderboard_service_spec.rb`. Inside the existing top-level `RSpec.describe Pvp::Leaderboards::SyncLeaderboardService do ... end`, append a new context after existing contexts:

```ruby
  context "snapshot writes" do
    let(:season) { create(:pvp_season) }
    let(:cycle)  { create(:pvp_sync_cycle, pvp_season: season) }
    let(:bracket) { "3v3" }
    let(:region)  { "us" }
    let(:snapshot_at) { Time.current.change(usec: 0) }

    before do
      stub_request(:get, %r{/data/wow/pvp-season/.*/pvp-leaderboard/3v3})
        .to_return(
          status: 200,
          body:   {
            "entries" => [
              {
                "character" => { "id" => 100, "name" => "Alpha", "realm" => { "slug" => "tichondrius" } },
                "rank" => 1, "rating" => 2800,
                "season_match_statistics" => { "won" => 50, "lost" => 20 }
              }
            ]
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "writes a snapshot row per entry with matching snapshot_at" do
      expect {
        described_class.call(season:, bracket:, region:, snapshot_at:, sync_cycle_id: cycle.id)
      }.to change { PvpLeaderboardEntrySnapshot.count }.by(1)

      snap = PvpLeaderboardEntrySnapshot.last
      expect(snap.snapshot_at).to be_within(1.second).of(snapshot_at)
      expect(snap.rank).to eq(1)
      expect(snap.rating).to eq(2800)
      expect(snap.pvp_sync_cycle_id).to eq(cycle.id)
    end

    it "is idempotent on replay (same snapshot_at)" do
      described_class.call(season:, bracket:, region:, snapshot_at:, sync_cycle_id: cycle.id)
      expect {
        described_class.call(season:, bracket:, region:, snapshot_at:, sync_cycle_id: cycle.id)
      }.not_to change { PvpLeaderboardEntrySnapshot.count }
    end

    it "isolates snapshot failures from primary entry writes" do
      allow(PvpLeaderboardEntrySnapshot).to receive(:insert_all).and_raise(StandardError, "snapshot boom")
      allow(Sentry).to receive(:capture_exception)

      result = described_class.call(season:, bracket:, region:, snapshot_at:, sync_cycle_id: cycle.id)

      expect(result).to be_success
      expect(PvpLeaderboardEntry.count).to eq(1)
      expect(PvpLeaderboardEntrySnapshot.count).to eq(0)
      expect(Sentry).to have_received(:capture_exception)
    end
  end
```

If the suite already stubs Blizzard for other contexts via shared examples, prefer reusing them — adapt the stubbing accordingly.

- [ ] **Step 2: Run spec to verify failures**

```bash
bundle exec rspec spec/services/pvp/leaderboards/sync_leaderboard_service_spec.rb
```

Expected: 3 new examples FAIL (`unknown keyword: sync_cycle_id`, no snapshot rows, etc.).

- [ ] **Step 3: Update service signature + write block**

Open `app/services/pvp/leaderboards/sync_leaderboard_service.rb`.

Replace the `initialize` method:

```ruby
def initialize(season:, bracket:, region:, locale: "en_US", snapshot_at: Time.current, sync_cycle_id: nil)
  @season         = season
  @bracket        = bracket
  @region         = region
  @locale         = locale
  @snapshot_at    = snapshot_at
  @sync_cycle_id  = sync_cycle_id
end
```

Add `:sync_cycle_id` to the existing `attr_reader` list in `private`:

```ruby
attr_reader :season, :bracket, :region, :locale, :snapshot_at, :sync_cycle_id
```

Inside `#call`, locate the `with_deadlock_retry do` block that wraps the leaderboard `with_lock`/`ActiveRecord::Base.transaction`. Capture `entry_records` so it survives outside the txn (the existing block already builds them) — they're already in `entry_records` local. Verify by reading the surrounding code; if the local goes out of scope, hoist its declaration above `with_deadlock_retry`.

After the `with_deadlock_retry` block returns, before the `Rails.logger.info("[SyncLeaderboardService] #{region}/#{bracket}: ...")` line, insert:

```ruby
write_snapshots(entry_records)
```

Add the helper method in the `private` section:

```ruby
def write_snapshots(entry_records)
  return if entry_records.blank?

  rows = entry_records.map do |r|
    {
      character_id:       r[:character_id],
      pvp_leaderboard_id: r[:pvp_leaderboard_id],
      pvp_sync_cycle_id:  sync_cycle_id,
      snapshot_at:        snapshot_at,
      rank:               r[:rank],
      rating:             r[:rating],
      wins:               r[:wins],
      losses:             r[:losses],
      spec_id:            r[:spec_id],
      created_at:         Time.current,
      updated_at:         Time.current
    }
  end

  inserted = PvpLeaderboardEntrySnapshot.insert_all(
    rows,
    unique_by: %i[character_id pvp_leaderboard_id snapshot_at],
    returning: false
  )
  count = inserted.respond_to?(:rows) ? inserted.rows.size : rows.size
  leaderboard = PvpLeaderboard.find_by(pvp_season_id: season.id, region: region, bracket: bracket)
  Pvp::SyncLogger.snapshots_inserted(count: count, leaderboard: leaderboard) if leaderboard
rescue => e
  Rails.logger.error("[SyncLeaderboardService] Snapshot insert failed: #{e.message}")
  Sentry.capture_exception(e, extra: {
    service:        "SyncLeaderboardService",
    region:         region,
    bracket:        bracket,
    snapshot_at:    snapshot_at,
    sync_cycle_id:  sync_cycle_id
  })
end
```

If `entry_records` is currently scoped inside the `with_deadlock_retry` block, hoist its assignment to a `let`-like form before the block:

```ruby
entry_records = []
with_deadlock_retry do
  ...
  entry_records = entries.map do |entry_json|
    ...
  end
  ...
end
```

so it's reachable after the block.

- [ ] **Step 4: Run service spec to verify it passes**

```bash
bundle exec rspec spec/services/pvp/leaderboards/sync_leaderboard_service_spec.rb
```

Expected: all examples PASS, including the 3 new ones.

- [ ] **Step 5: Run full suite to catch fallout**

```bash
bundle exec rspec
```

Expected: 0 failures. If callers of `SyncLeaderboardService` break because of the new `sync_cycle_id:` kwarg — none should, since it's optional with default `nil`.

- [ ] **Step 6: Commit**

```bash
git add app/services/pvp/leaderboards/sync_leaderboard_service.rb spec/services/pvp/leaderboards/sync_leaderboard_service_spec.rb
git commit -m "feat(sync): write leaderboard entry snapshots in SyncLeaderboardService"
```

---

## Task 5: Pass sync_cycle_id from orchestrator job

**Files:**
- Modify: `app/jobs/pvp/sync_current_season_leaderboards_job.rb`

- [ ] **Step 1: Update the SyncLeaderboardService call site**

Open `app/jobs/pvp/sync_current_season_leaderboards_job.rb`. Find the block:

```ruby
result = Pvp::Leaderboards::SyncLeaderboardService.call(
  season:      season,
  bracket:     task[:bracket],
  region:      task[:region],
  locale:      task[:locale],
  snapshot_at: snapshot_at
)
```

Add `sync_cycle_id:`:

```ruby
result = Pvp::Leaderboards::SyncLeaderboardService.call(
  season:        season,
  bracket:       task[:bracket],
  region:        task[:region],
  locale:        task[:locale],
  snapshot_at:   snapshot_at,
  sync_cycle_id: sync_cycle.id
)
```

`sync_cycle` is the local variable already in scope (created earlier in `#perform`).

- [ ] **Step 2: Run the orchestrator job spec**

```bash
bundle exec rspec spec/jobs/pvp/sync_current_season_leaderboards_job_spec.rb
```

Expected: all examples PASS. The orchestrator spec should already mock `SyncLeaderboardService.call` and tolerate extra kwargs. If it asserts on exact kwargs, update the assertion to include `sync_cycle_id`.

- [ ] **Step 3: Commit**

```bash
git add app/jobs/pvp/sync_current_season_leaderboards_job.rb spec/jobs/pvp/sync_current_season_leaderboards_job_spec.rb
git commit -m "feat(sync): pass sync_cycle_id into SyncLeaderboardService"
```

---

## Task 6: LeaderboardDeltasQuery (24-48h baseline)

**Files:**
- Create: `app/services/pvp/leaderboards/leaderboard_deltas_query.rb`
- Create: `spec/services/pvp/leaderboards/leaderboard_deltas_query_spec.rb`

- [ ] **Step 1: Write the failing spec**

```ruby
# spec/services/pvp/leaderboards/leaderboard_deltas_query_spec.rb
require "rails_helper"

RSpec.describe Pvp::Leaderboards::LeaderboardDeltasQuery do
  let(:season)      { create(:pvp_season) }
  let(:leaderboard) { create(:pvp_leaderboard, pvp_season: season, bracket: "3v3", region: "us") }
  let(:char_a)      { create(:character) }
  let(:char_b)      { create(:character) }
  let(:char_c)      { create(:character) }

  before do
    # 30h-old snapshot for A — inside 24-48h window → baseline
    create(:pvp_leaderboard_entry_snapshot,
           character: char_a, pvp_leaderboard: leaderboard,
           snapshot_at: 30.hours.ago,
           rank: 100, rating: 2400, wins: 40, losses: 30)
    # 12h-old for A — outside window (too recent)
    create(:pvp_leaderboard_entry_snapshot,
           character: char_a, pvp_leaderboard: leaderboard,
           snapshot_at: 12.hours.ago,
           rank: 50, rating: 2600, wins: 50, losses: 32)

    # 6d-old for B — outside window (too stale)
    create(:pvp_leaderboard_entry_snapshot,
           character: char_b, pvp_leaderboard: leaderboard,
           snapshot_at: 6.days.ago,
           rank: 200, rating: 2200, wins: 10, losses: 5)

    # No snapshots for C
  end

  it "returns the most-recent snapshot at-or-before 24h ago, capped at 48h" do
    deltas = described_class.new(leaderboard.id).call

    expect(deltas[char_a.id]).to include(rank: 100, rating: 2400, wins: 40, losses: 30)
    expect(deltas[char_b.id]).to be_nil
    expect(deltas[char_c.id]).to be_nil
  end

  it "scopes to the requested leaderboard" do
    other_lb = create(:pvp_leaderboard, pvp_season: season, bracket: "2v2", region: "us")
    create(:pvp_leaderboard_entry_snapshot,
           character: char_a, pvp_leaderboard: other_lb,
           snapshot_at: 30.hours.ago,
           rank: 999, rating: 9999, wins: 0, losses: 0)

    deltas = described_class.new(leaderboard.id).call
    expect(deltas[char_a.id][:rank]).to eq(100)
  end
end
```

- [ ] **Step 2: Run spec to verify it fails**

```bash
bundle exec rspec spec/services/pvp/leaderboards/leaderboard_deltas_query_spec.rb
```

Expected: FAIL — uninitialized constant `Pvp::Leaderboards::LeaderboardDeltasQuery`.

- [ ] **Step 3: Implement the query**

```ruby
# app/services/pvp/leaderboards/leaderboard_deltas_query.rb
module Pvp
  module Leaderboards
    # Returns Hash[character_id => { rank:, rating:, wins:, losses: }]
    # for the most-recent snapshot in the 24-48h window prior to `now`.
    # Returns an empty Hash when no qualifying snapshots exist.
    class LeaderboardDeltasQuery
      def initialize(leaderboard_id, now: Time.current)
        @leaderboard_id = leaderboard_id
        @now            = now
      end

      def call
        rows = ApplicationRecord.connection.select_all(
          ApplicationRecord.sanitize_sql_array([
            sql,
            { leaderboard_id: leaderboard_id, lower: now - 48.hours, upper: now - 24.hours }
          ])
        )
        rows.each_with_object({}) do |r, h|
          h[r["character_id"].to_i] = {
            rank:   r["rank"].to_i,
            rating: r["rating"].to_i,
            wins:   r["wins"].to_i,
            losses: r["losses"].to_i
          }
        end
      end

      private

        attr_reader :leaderboard_id, :now

        def sql
          <<~SQL
            SELECT DISTINCT ON (character_id)
              character_id, rank, rating, wins, losses, snapshot_at
            FROM pvp_leaderboard_entry_snapshots
            WHERE pvp_leaderboard_id = :leaderboard_id
              AND snapshot_at <= :upper
              AND snapshot_at >= :lower
            ORDER BY character_id, snapshot_at DESC
          SQL
        end
    end
  end
end
```

- [ ] **Step 4: Run spec to verify it passes**

```bash
bundle exec rspec spec/services/pvp/leaderboards/leaderboard_deltas_query_spec.rb
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/services/pvp/leaderboards/leaderboard_deltas_query.rb spec/services/pvp/leaderboards/leaderboard_deltas_query_spec.rb
git commit -m "feat(query): add LeaderboardDeltasQuery for 24h delta lookup"
```

---

## Task 7: Per-entry serializer + leaderboard delta in response

**Files:**
- Create: `app/serializers/pvp/leaderboard_entry_serializer.rb`
- Modify: `app/controllers/api/v1/pvp/leaderboards_controller.rb`
- Modify: `spec/requests/api/v1/pvp/leaderboards_spec.rb`

- [ ] **Step 1: Add request-spec coverage for the delta field**

If `spec/requests/api/v1/pvp/leaderboards_spec.rb` doesn't exist, create it:

```ruby
require "rails_helper"

RSpec.describe "GET /api/v1/pvp/:season/:region/leaderboards/:bracket", type: :request do
  let(:season)      { create(:pvp_season, blizzard_id: 42) }
  let(:leaderboard) { create(:pvp_leaderboard, pvp_season: season, bracket: "3v3", region: "us") }
  let(:char)        { create(:character) }

  before do
    create(:pvp_leaderboard_entry,
           character: char, pvp_leaderboard: leaderboard,
           rank: 1, rating: 2800, wins: 50, losses: 20)
  end

  context "when a 24h baseline snapshot exists" do
    before do
      create(:pvp_leaderboard_entry_snapshot,
             character: char, pvp_leaderboard: leaderboard,
             snapshot_at: 30.hours.ago,
             rank: 5, rating: 2700, wins: 40, losses: 18)
    end

    it "includes a delta object on the entry" do
      get "/api/v1/pvp/#{season.blizzard_id}/us/leaderboards/3v3"
      expect(response).to have_http_status(:ok)
      entry = response.parsed_body.first
      expect(entry["delta"]).to eq(
        "rank"   => -4,
        "rating" => 100,
        "wins"   => 10,
        "losses" => 2
      )
    end
  end

  context "when no baseline snapshot exists" do
    it "returns delta as null" do
      get "/api/v1/pvp/#{season.blizzard_id}/us/leaderboards/3v3"
      expect(response.parsed_body.first["delta"]).to be_nil
    end
  end
end
```

If a spec already exists, append the two contexts inside the existing top-level `RSpec.describe` block.

- [ ] **Step 2: Run spec to verify failure**

```bash
bundle exec rspec spec/requests/api/v1/pvp/leaderboards_spec.rb
```

Expected: FAIL — response shape lacks `"delta"`.

- [ ] **Step 3: Write the serializer**

```ruby
# app/serializers/pvp/leaderboard_entry_serializer.rb
module Pvp
  class LeaderboardEntrySerializer
    def initialize(entry, delta: nil)
      @entry = entry
      @delta = delta
    end

    def call
      {
        character_id: entry.character_id,
        rank:         entry.rank,
        rating:       entry.rating,
        wins:         entry.wins,
        losses:       entry.losses,
        spec_id:      entry.spec_id,
        snapshot_at:  entry.snapshot_at,
        delta:        delta_payload
      }
    end

    private

      attr_reader :entry, :delta

      def delta_payload
        return nil if delta.nil?

        {
          rank:   entry.rank   - delta[:rank],
          rating: entry.rating - delta[:rating],
          wins:   entry.wins   - delta[:wins],
          losses: entry.losses - delta[:losses]
        }
      end
  end
end
```

- [ ] **Step 4: Update the controller to use it**

Replace the body of `app/controllers/api/v1/pvp/leaderboards_controller.rb` with:

```ruby
class Api::V1::Pvp::LeaderboardsController < Api::V1::BaseController
  MIXED_BRACKETS = %w[2v2 3v3 rbg].freeze

  before_action :set_season, :set_leaderboard, only: [ :show ]

  def show
    entries = @leaderboard.get_top_n(10, spec_id: spec_id_param)
    deltas  = Pvp::Leaderboards::LeaderboardDeltasQuery.new(@leaderboard.id).call

    payload = entries.map do |entry|
      Pvp::LeaderboardEntrySerializer.new(entry, delta: deltas[entry.character_id]).call
    end

    render json: payload
  end

  private

    def set_season
      @season = PvpSeason.find_by!(blizzard_id: params[:season])
    end

    def set_leaderboard
      @leaderboard = PvpLeaderboard.find_by!(
        pvp_season: @season,
        region:     params[:region],
        bracket:    params[:bracket]
      )
    end

    def spec_id_param
      return unless MIXED_BRACKETS.include?(params[:bracket])

      params.require(:spec_id).to_i
    end
end
```

- [ ] **Step 5: Run spec to verify pass**

```bash
bundle exec rspec spec/requests/api/v1/pvp/leaderboards_spec.rb
```

Expected: PASS.

- [ ] **Step 6: Run full suite**

```bash
bundle exec rspec
```

Expected: 0 failures. If a previously passing test asserted on the exact prior response shape (without `delta`), update that test to allow the new field.

- [ ] **Step 7: Commit**

```bash
git add app/controllers/api/v1/pvp/leaderboards_controller.rb app/serializers/pvp/leaderboard_entry_serializer.rb spec/requests/api/v1/pvp/leaderboards_spec.rb
git commit -m "feat(api): add 24h delta to leaderboard entries"
```

---

## Task 8: Profile sparkline endpoint

**Files:**
- Create: `app/controllers/api/v1/characters/trends_controller.rb`
- Create: `spec/requests/api/v1/characters/trends_spec.rb`
- Modify: `config/routes.rb`

- [ ] **Step 1: Write the failing request spec**

```ruby
# spec/requests/api/v1/characters/trends_spec.rb
require "rails_helper"

RSpec.describe "GET /api/v1/characters/:region/:realm/:name/trends", type: :request do
  let(:season)      { create(:pvp_season) }
  let(:leaderboard) { create(:pvp_leaderboard, pvp_season: season, bracket: "3v3", region: "us") }
  let(:char)        { create(:character, region: "us", realm: "tichondrius", name: "alpha") }

  before do
    create(:pvp_leaderboard_entry_snapshot,
           character: char, pvp_leaderboard: leaderboard,
           snapshot_at: 6.hours.ago,
           rank: 5, rating: 2810, wins: 42, losses: 18)
    create(:pvp_leaderboard_entry_snapshot,
           character: char, pvp_leaderboard: leaderboard,
           snapshot_at: 30.hours.ago,
           rank: 8, rating: 2778, wins: 38, losses: 16)
    # Outside 7d window — should be filtered out
    create(:pvp_leaderboard_entry_snapshot,
           character: char, pvp_leaderboard: leaderboard,
           snapshot_at: 10.days.ago,
           rank: 50, rating: 2400, wins: 5, losses: 1)
  end

  it "returns trend snapshots grouped by bracket within the 7d window" do
    get "/api/v1/characters/us/tichondrius/alpha/trends"
    expect(response).to have_http_status(:ok)

    body = response.parsed_body
    expect(body["character"]).to include("name" => "alpha", "realm" => "tichondrius", "region" => "us")
    expect(body["trends"].size).to eq(1)

    trend = body["trends"].first
    expect(trend["bracket"]).to eq("3v3")
    expect(trend["snapshots"].size).to eq(2)
    expect(trend["snapshots"].first["rating"]).to eq(2778) # ascending by snapshot_at
    expect(trend["snapshots"].last["rating"]).to eq(2810)
  end

  it "404s for unknown character" do
    get "/api/v1/characters/us/tichondrius/missing/trends"
    expect(response).to have_http_status(:not_found)
  end
end
```

- [ ] **Step 2: Run spec to verify it fails**

```bash
bundle exec rspec spec/requests/api/v1/characters/trends_spec.rb
```

Expected: FAIL — `ActionController::RoutingError` (no route).

- [ ] **Step 3: Add the route**

In `config/routes.rb`, locate the existing line:

```ruby
get "characters/:region/:realm/:name", to: "characters#show", as: :character_profile
```

Add the trends route directly below it, inside the same scope:

```ruby
get "characters/:region/:realm/:name/trends",
    to:   "characters/trends#show",
    as:   :character_trends
```

- [ ] **Step 4: Implement the controller**

```ruby
# app/controllers/api/v1/characters/trends_controller.rb
module Api
  module V1
    module Characters
      class TrendsController < Api::V1::BaseController
        WINDOW = 7.days

        def show
          character = find_character
          return render_not_found if character.nil?

          render json: { character: character_payload(character), trends: build_trends(character) }
        end

        private

          def find_character
            Character.find_by(
              "LOWER(region) = ? AND LOWER(realm) = ? AND LOWER(name) = ?",
              params[:region].downcase, params[:realm].downcase, params[:name].downcase
            )
          end

          def render_not_found
            render json: { error: "Not found" }, status: :not_found
          end

          def character_payload(character)
            { name: character.name, realm: character.realm, region: character.region }
          end

          def build_trends(character)
            rows = PvpLeaderboardEntrySnapshot
              .joins(:pvp_leaderboard)
              .where(character_id: character.id)
              .where("snapshot_at >= ?", WINDOW.ago)
              .order("pvp_leaderboards.bracket ASC, pvp_leaderboard_entry_snapshots.snapshot_at ASC")
              .pluck("pvp_leaderboards.bracket",
                     "pvp_leaderboards.region",
                     :snapshot_at, :rank, :rating, :wins, :losses, :spec_id)

            rows.group_by { |bracket, *| bracket }.map do |bracket, group|
              {
                bracket:   bracket,
                region:    group.first[1],
                snapshots: group.map { |_b, _r, at, rank, rating, wins, losses, spec_id|
                  { at: at, rank: rank, rating: rating, wins: wins, losses: losses, spec_id: spec_id }
                }
              }
            end
          end
      end
    end
  end
end
```

- [ ] **Step 5: Run spec to verify pass**

```bash
bundle exec rspec spec/requests/api/v1/characters/trends_spec.rb
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/controllers/api/v1/characters/trends_controller.rb spec/requests/api/v1/characters/trends_spec.rb config/routes.rb
git commit -m "feat(api): add /characters/.../trends sparkline endpoint"
```

---

## Task 9: Prune job

**Files:**
- Create: `app/jobs/pvp/prune_leaderboard_snapshots_job.rb`
- Create: `spec/jobs/pvp/prune_leaderboard_snapshots_job_spec.rb`
- Modify: `config/recurring.yml`

- [ ] **Step 1: Write the failing job spec**

```ruby
# spec/jobs/pvp/prune_leaderboard_snapshots_job_spec.rb
require "rails_helper"

RSpec.describe Pvp::PruneLeaderboardSnapshotsJob, type: :job do
  let(:leaderboard) { create(:pvp_leaderboard) }
  let(:char)        { create(:character) }

  before do
    create(:pvp_leaderboard_entry_snapshot,
           character: char, pvp_leaderboard: leaderboard,
           snapshot_at: 8.days.ago)
    create(:pvp_leaderboard_entry_snapshot,
           character: char, pvp_leaderboard: leaderboard,
           snapshot_at: 6.days.ago)
    create(:pvp_leaderboard_entry_snapshot,
           character: char, pvp_leaderboard: leaderboard,
           snapshot_at: 1.hour.ago)
  end

  it "deletes snapshots older than 7 days" do
    expect {
      described_class.new.perform
    }.to change { PvpLeaderboardEntrySnapshot.count }.from(3).to(2)
  end

  it "leaves rows newer than the cutoff intact" do
    described_class.new.perform
    remaining = PvpLeaderboardEntrySnapshot.pluck(:snapshot_at)
    remaining.each { |t| expect(t).to be > 7.days.ago }
  end
end
```

- [ ] **Step 2: Run spec to verify it fails**

```bash
bundle exec rspec spec/jobs/pvp/prune_leaderboard_snapshots_job_spec.rb
```

Expected: FAIL — uninitialized constant `Pvp::PruneLeaderboardSnapshotsJob`.

- [ ] **Step 3: Implement the job**

```ruby
# app/jobs/pvp/prune_leaderboard_snapshots_job.rb
module Pvp
  class PruneLeaderboardSnapshotsJob < ApplicationJob
    queue_as :default

    RETENTION  = 7.days
    BATCH_SIZE = 10_000

    def perform
      cutoff = RETENTION.ago
      total  = 0

      loop do
        n = PvpLeaderboardEntrySnapshot
          .where("snapshot_at < ?", cutoff)
          .limit(BATCH_SIZE)
          .delete_all
        total += n
        break if n.zero?
      end

      Rails.logger.info("[PruneLeaderboardSnapshotsJob] Deleted #{total} rows older than #{cutoff}")
    end
  end
end
```

- [ ] **Step 4: Run spec to verify it passes**

```bash
bundle exec rspec spec/jobs/pvp/prune_leaderboard_snapshots_job_spec.rb
```

Expected: PASS.

- [ ] **Step 5: Schedule the job**

Open `config/recurring.yml`. Inside the `production:` block (and any other env that already declares recurring jobs), append:

```yaml
  prune_leaderboard_snapshots:
    class: Pvp::PruneLeaderboardSnapshotsJob
    schedule: every day at 3am UTC
```

- [ ] **Step 6: Commit**

```bash
git add app/jobs/pvp/prune_leaderboard_snapshots_job.rb spec/jobs/pvp/prune_leaderboard_snapshots_job_spec.rb config/recurring.yml
git commit -m "feat(jobs): add daily PruneLeaderboardSnapshotsJob (7d retention)"
```

---

## Task 10: RBS signatures

**Files:**
- Create: `sig/pvp/leaderboards/leaderboard_deltas_query.rbs`
- Modify: `sig/pvp/leaderboards/sync_leaderboard_service.rbs` (only if it exists; otherwise skip)

- [ ] **Step 1: Write the new query sig**

```rbs
# sig/pvp/leaderboards/leaderboard_deltas_query.rbs
module Pvp
  module Leaderboards
    class LeaderboardDeltasQuery
      def initialize: (Integer leaderboard_id, ?now: Time) -> void
      def call: () -> Hash[Integer, { rank: Integer, rating: Integer, wins: Integer, losses: Integer }]
    end
  end
end
```

- [ ] **Step 2: Update sync_leaderboard_service.rbs (if present)**

```bash
ls sig/pvp/leaderboards/sync_leaderboard_service.rbs 2>/dev/null && echo present
```

If `present`, edit the `def initialize` line to include `?sync_cycle_id: Integer?` after `?snapshot_at: Time`. Otherwise skip this step.

- [ ] **Step 3: Run steep check**

```bash
bundle exec steep check
```

Expected: 0 errors (existing warnings are acceptable; do not fix them in this task).

- [ ] **Step 4: Commit**

```bash
git add sig/
git commit -m "chore(types): RBS sigs for trends additions"
```

---

## Task 11: End-to-end verification

- [ ] **Step 1: Run the full test suite**

```bash
bundle exec rspec
```

Expected: all examples PASS, 0 failures. Coverage report should reflect the new code.

- [ ] **Step 2: Run rubocop**

```bash
bundle exec rubocop
```

Expected: no offenses on touched files. Auto-fix safe ones with `--autocorrect` if desired.

- [ ] **Step 3: Smoke-check the leaderboard endpoint**

```bash
bundle exec rails runner '
season = PvpSeason.current
lb = PvpLeaderboard.where(pvp_season: season, bracket: "3v3", region: "us").first
puts "leaderboard_id: #{lb&.id}"
puts "entries: #{lb&.entries&.count}"
puts "deltas: #{Pvp::Leaderboards::LeaderboardDeltasQuery.new(lb.id).call.size}" if lb
'
```

Expected: positive entry + delta counts (delta count grows as 24h-old snapshots accumulate post-deploy).

- [ ] **Step 4: Confirm prune runs cleanly**

```bash
bundle exec rails runner 'Pvp::PruneLeaderboardSnapshotsJob.new.perform'
```

Expected: log line `[PruneLeaderboardSnapshotsJob] Deleted 0 rows older than ...` (no rows older than 7d in fresh-deploy state).

- [ ] **Step 5: Final commit (if any leftover files)**

```bash
git status
```

If clean, no commit needed. Otherwise stage and commit any straggler config/format fixes with a meaningful message.

---

## Self-Review

**Spec coverage check (against `docs/superpowers/specs/2026-05-07-bracket-trends-design.md`):**

| Spec section | Implemented in |
|---|---|
| Schema (table + 3 indexes + cycle_id + spec_id) | Task 1 |
| Day-0 backfill | Task 1 |
| Volume math | (Spec only — not code) |
| Write path (isolated rescue) | Task 4 |
| Deadlock analysis | (Spec only — informs Task 4 design) |
| 24h leaderboard delta query | Tasks 6 + 7 |
| Trends endpoint | Task 8 |
| Caching (existing meta_cache_fetch + 5min trends TTL) | Task 7 / Task 8 (relies on existing helpers — explicit caching can be layered later if hot) |
| Pruning job | Task 9 |
| Day-0 + post-deploy timeline | (Spec only — UX expectation) |
| Edge cases | Tasks 6, 7, 8 (request specs cover null delta, missing char, 7d window) |
| Test plan | Tasks 2, 4, 6, 7, 8, 9 |
| File touches | All matched |

**Placeholder scan:** No `TBD`, `TODO`, "implement later", or unspecified error handling. All steps include exact code or commands.

**Type consistency:** `LeaderboardDeltasQuery` constructor in Task 6 takes `leaderboard_id` and exposes `#call`. Task 7 uses `Pvp::Leaderboards::LeaderboardDeltasQuery.new(@leaderboard.id).call` — match. Serializer in Task 7 uses `delta:` kwarg, controller passes `delta: deltas[entry.character_id]` — match. SyncLeaderboardService's new `sync_cycle_id:` kwarg lines up between Task 4 (definition) and Task 5 (caller).

**Caching note:** trends endpoint isn't explicitly wrapped in `meta_cache_fetch` in Task 8 — the spec mentions "5 min TTL" as a future hardening. If the endpoint becomes hot, wrap the JSON build in `meta_cache_fetch("trends", char.id, season.id)`; not required for v1.
