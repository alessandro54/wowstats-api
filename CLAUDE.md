# AGENTS.md

Shared guidance for all AI agents working in `bis/` (Rails API).

## Repository Structure

Standalone Rails API-only app (Rails 8.1, Ruby 4.0.1). Frontend lives in a separate repository (`bis-web/`). All commands run from the repo root.

## Commands

```bash
# Development
bundle exec rails server                                                  # API on :3000
bundle exec rails solid_queue:start                                       # background job worker
bundle exec rails console

# Tests
bundle exec rspec                                                          # full suite
bundle exec rspec spec/services/pvp/                                      # directory
bundle exec rspec spec/jobs/pvp/sync_character_batch_job_spec.rb          # single file

# Linting & type checking
bundle exec rubocop
bundle exec rubocop --autocorrect
bundle exec steep check

# Database
bundle exec rails db:create db:migrate
bundle exec rails db:schema:load   # faster for fresh setup
```

## Architecture

### What it does

WoW BIS tracks World of Warcraft PvP leaderboard data (US/EU). It ingests character equipment and talent data from the Blizzard API, runs aggregations to compute PvP meta statistics (item/enchant/gem/talent popularity, stat priority, class distribution, top players), and exposes results via a versioned JSON API at `/api/v1/`.

### API Routes

```
GET  /up                                             # health check
GET  /api-docs                                       # OpenAPI UI
GET  /api-docs/openapi.yaml                          # OpenAPI spec

GET  /api/v1/characters                              # character index
GET  /api/v1/characters/:region/:realm/:name         # character profile

GET  /api/v1/pvp/:season/:region/leaderboards/:bracket  # raw leaderboard data

GET  /api/v1/pvp/meta/items                          # ?bracket=&spec_id=&locale=
GET  /api/v1/pvp/meta/enchants                       # ?bracket=&spec_id=&locale=
GET  /api/v1/pvp/meta/gems                           # ?bracket=&spec_id=&locale=
GET  /api/v1/pvp/meta/specs                          # spec list
GET  /api/v1/pvp/meta/specs/:id                      # single spec
GET  /api/v1/pvp/meta/talents                        # ?bracket=&spec_id=&locale=
GET  /api/v1/pvp/meta/top_players                    # ?bracket=&spec_id=&region=&locale=
GET  /api/v1/pvp/meta/stat_priority                  # ?bracket=&spec_id=&locale=
GET  /api/v1/pvp/meta/class_distribution             # ?season_id=&bracket=&region=&role=&locale=

GET  /admin/dashboard
GET  /jobs                                           # Mission Control job UI
GET  /avo                                            # Avo admin panel
```

### Controllers (`app/controllers/api/v1/`)

`Api::V1::BaseController` provides shared helpers to all meta controllers:
- `meta_cache_key(*segments)` — versioned cache key; all meta caches can be busted at once by incrementing `pvp_meta/version` in Rails.cache
- `meta_cache_fetch(cache_key, expires_in: 30.minutes)` — skips caching in development
- `set_cache_headers(max_age: 5.minutes, stale_while_revalidate: 1.hour)` — Cache-Control for CDN
- `current_season` — memoized `PvpSeason.current`
- `locale_param` — validates against `Wow::Locales::SUPPORTED_LOCALES`, falls back to `"en_US"`

### Models (`app/models/`)

| Model | Table | Notes |
|---|---|---|
| `Character` | `characters` | Core entity; has equipment, talents, leaderboard entries; stores `stat_pcts` as jsonb, `spec_talent_loadout_codes` as jsonb |
| `CharacterItem` | `character_items` | Equipment snapshot per character |
| `CharacterTalent` | `character_talents` | Talent loadout per character |
| `Item` | `items` | Blizzard item; includes `Translatable` |
| `Enchantment` | `enchantments` | includes `Translatable` |
| `Talent` | `talents` | `talent_type`: `class/spec/hero/pvp`; `node_id`, `display_row/col` for tree layout; includes `Translatable` |
| `TalentPrerequisite` | `talent_prerequisites` | Prerequisite node edges for talent tree |
| `TalentSpecAssignment` | `talent_spec_assignments` | Links talents to spec IDs with `default_points` |
| `Translation` | `translations` | Polymorphic i18n storage (via `Translatable` concern) |
| `PvpSeason` | `pvp_seasons` | Tracks current season; `PvpSeason.current` |
| `PvpLeaderboard` | `pvp_leaderboards` | Per-bracket/region/season leaderboard snapshot |
| `PvpLeaderboardEntry` | `pvp_leaderboard_entries` | Individual character entries; stores `raw_equipment`/`raw_specialization` as compressed `bytea` (zstd) |
| `PvpSyncCycle` | `pvp_sync_cycles` | Tracks a full sync run; atomic batch completion counter |
| `PvpMetaItemPopularity` | `pvp_meta_item_popularities` | Aggregated item usage per bracket/spec/season |
| `PvpMetaEnchantPopularity` | `pvp_meta_enchant_popularities` | Aggregated enchant usage |
| `PvpMetaGemPopularity` | `pvp_meta_gem_popularities` | Aggregated gem usage |
| `PvpMetaTalentPopularity` | `pvp_meta_talent_popularities` | Aggregated talent usage; includes `in_top_build`, `top_build_rank`, `tier` |
| `JobPerformanceMetric` | `job_performance_metrics` | Duration/success tracking per job (via `JobPerformanceMonitor`) |

#### `Translatable` Concern

`Item`, `Enchantment`, and `Talent` all include `Translatable`. This adds:
- `has_many :translations` (polymorphic via `Translation`)
- `t(key, locale:)` — lookup translation; falls back to `en_US` if locale not found
- `set_translation(key, locale, value)` — upsert a translation
- `translation_accessor :name, :description` — declares locale-aware attribute methods

### Sync Pipeline

Four-phase pipeline, all jobs under `app/jobs/pvp/`:

1. **`Pvp::SyncCurrentSeasonLeaderboardsJob`** — orchestrator; creates a `PvpSyncCycle`, discovers brackets for US+EU concurrently, calls `SyncLeaderboardService` per bracket, then enqueues `SyncCharacterBatchJob` batches to region-isolated queues (`character_sync_us`, `character_sync_eu`). Skips if a cycle is already active (notifies Telegram). Accepts `locale:` param.
2. **`Pvp::SyncCharacterBatchJob`** — processes a batch of characters concurrently via threads; calls `SyncCharacterService` per character; atomically increments `PvpSyncCycle#completed_character_batches` and triggers `BuildAggregationsJob` when all batches finish. Skips entire batch if cycle status is `:aborted`.
3. **`Pvp::BuildAggregationsJob`** — runs `ItemAggregationService`, `EnchantAggregationService`, `GemAggregationService`, `TalentAggregationService`, and `BayesianClassDistributionService` per bracket. Skips if cycle is `:aborted`.
4. **`Pvp::SyncBracketJob`** — standalone single-bracket sync (no sync cycle), for ad-hoc/manual use.

`PvpSyncCycle` status machine: `syncing_leaderboards → syncing_characters → completed / failed / aborted`. Abort is set via Telegram `/abort <id>` or button; all in-flight batch and aggregation jobs respect it.

### Other Jobs

| Job | Queue | Purpose |
|---|---|---|
| `Characters::SyncCharacterJob` | default | Single character sync |
| `Characters::SyncCharacterMetaBatchJob` | default | Refresh character metadata (class, spec, avatar) |
| `Items::SyncItemMetaBatchJob` | default | Fetch item metadata (icons, names) from Blizzard API |
| `SyncTalentTreesJob` | default | Sync full talent tree from Blizzard API via `Blizzard::Data::Talents::SyncTreeService` |
| `EnsureMetaTranslationsJob` | default | Ensure `en_US`/`es_MX` translations exist for all items, enchantments, talents in current meta |
| `Pvp::RecoverFailedCharacterSyncsJob` | default | Re-enqueues unprocessed characters from a cycle; triggered when all batches complete |
| `Pvp::NotifyCycleProgressJob` | default | Sends Telegram milestone notification (25/50/75%) |
| `Pvp::NotifyFailedCharactersJob` | default | Sends `.txt` report if failed characters exceed 5% threshold |
| `Pvp::DetectStaleCycleJob` | default | Recurring; alerts Telegram if a cycle has been stuck in `syncing_characters` for >2h |

### Service Pattern

All services extend `BaseService`, called via `.call(...)`, return `ServiceResult` with `#success?`, `#failure?`, `#error`, `#payload`, `#context`.

```
app/services/
├── pvp/
│   ├── characters/
│   │   ├── sync_character_service.rb
│   │   └── compute_stat_totals_service.rb
│   ├── leaderboards/
│   │   └── sync_leaderboard_service.rb
│   ├── entries/
│   │   ├── process_equipment_service.rb
│   │   └── process_specialization_service.rb
│   └── meta/
│       ├── aggregation_sql.rb
│       ├── item_aggregation_service.rb
│       ├── enchant_aggregation_service.rb
│       ├── gem_aggregation_service.rb
│       ├── talent_aggregation_service.rb
│       └── class_distribution_service.rb
├── blizzard/
│   ├── auth.rb, auth_pool.rb, client.rb, rate_limiter.rb
│   ├── api/game_data/     # item, item_media, pvp_season, talent, pvp_talent, talent_media
│   ├── api/profile/       # character_equipment_summary, _media_summary, _profile_summary, _specialization_summary, _statistics_summary
│   └── data/
│       ├── items/upsert_from_raw_equipment_service.rb
│       └── talents/sync_tree_service.rb, upsert_from_raw_specialization_service.rb
└── admin/
    └── dashboard_health_service.rb
```

### Concurrency Model

Jobs use two concurrency mechanisms:
- **Threads** (`run_with_threads`): used for Blizzard HTTP calls. `safe_concurrency` caps to `THREADS - 1` to prevent DB pool exhaustion.
- **Fibers** (`run_concurrently`, Async gem): available via `ApplicationJob` helpers.

Tunable via env vars: `PVP_SYNC_CONCURRENCY` (default 15), `PVP_SYNC_THREADS` (default 8), `PVP_SYNC_BATCH_SIZE` (default 50), `PVP_LEADERBOARD_CONCURRENCY` (default 10).

### Blizzard API

`Blizzard::Auth` manages OAuth tokens; `Blizzard::AuthPool` supports multiple client credentials for redundancy. `Blizzard::Client` wraps `httpx` for concurrent HTTP. Rate limiter enforces `PVP_BLIZZARD_RPS` (default 95.0 rps) and `PVP_BLIZZARD_HOURLY_QUOTA` (default 36,000).

### Data Storage

- Raw API responses (`raw_equipment`, `raw_specialization`) stored as `bytea` using `zstd-ruby` compression (~60% smaller)
- `oj` gem used for all JSON (via `Oj.optimize_rails` + `Oj.mimic_JSON` in initializer)
- Query cache enabled in all jobs via `around_perform :with_query_cache`
- `PvpSyncCycle` uses atomic DB increments to track batch completion without locking

### Databases (all PostgreSQL)

Multi-database Rails setup:
- `primary` — app data
- `queue` — SolidQueue backend
- `cache` — SolidCache backend (256MB max)
- `cable` — SolidCable backend

### Recurring Jobs (`config/recurring.yml`)

| Job | Schedule | Purpose |
|---|---|---|
| `Pvp::SyncCurrentSeasonLeaderboardsJob` | Every 6 hours | Full leaderboard + character sync |
| `EnsureMetaTranslationsJob` | Every 12 hours | Ensure all meta items/enchants/talents have i18n |
| `clear_solid_queue_finished_jobs` | Every hour at :12 | Prune finished job records |
| `Pvp::DetectStaleCycleJob` | Every 30 minutes | Alert if a cycle is stuck for >2h |

### Queue Configuration (`config/queue.yml`)

Production workers are region-isolated:
- `character_sync_us` / `character_sync_eu` — one dedicated worker per region (`PVP_SYNC_THREADS` threads each)
- Bracket queues (`pvp_sync_2v2`, `pvp_sync_3v3`, `pvp_sync_shuffle`, `pvp_sync_rbg`) — shared worker
- `pvp_processing` + catchall — shared worker

Set `QUEUE_PROFILE=low_resource` for a single-worker low-thread profile.

### Domain Constants (`app/lib/`)

- `Pvp::SyncConfig` — `EQUIPMENT_TTL` (1 hour), `META_TTL` (1 week)
- `Pvp::RegionConfig` — `REGIONS`, `REGION_QUEUES`, `REGION_LOCALES` for US/EU
- `Pvp::BracketConfig` — per-bracket settings: `top_n`, `rating_min`, `job_queue`. Families: `two_v_two`, `three_v_three`, `shuffle_like`, `rbg_like`, `default`
- `Pvp::SyncLogger` — structured logging for sync cycle events
- `Wow::Catalog` — all 40 specs mapped to class/role; helpers: `spec_slug(id)`, `class_slug_for_spec(id)`, `role_for_spec(id)`, `spec_id_from_bracket(bracket)`
- `Wow::Classes`, `Wow::Specs`, `Wow::Roles` — WoW game constants
- `Wow::Locales` — `SUPPORTED_LOCALES` (`["en_US", "es_MX"]`)
- `ServiceResult` — result object returned by all services
- `BatchOutcome` — tracks batch job outcomes
- `TelegramNotifier` — fire-and-forget Telegram Bot API client; `send`, `reply`, `reply_with_buttons`, `answer_callback_query`, `send_document`
- `TelegramCommandHandler` — handles inbound bot commands from whitelisted chat IDs; commands: `/help`, `/cycle [id]`, `/progress`, `/history`, `/errors`, `/jobs`, `/syncnow`, `/currentsync`, `/abort <id>`
- `TelegramCallbackHandler` — handles inline keyboard button presses; actions: `abort:<cycle_id>`, `retry:<cycle_id>`

### Key Environment Variables

| Variable | Default | Purpose |
|---|---|---|
| `BLIZZARD_CLIENT_ID` / `_SECRET` | — | Blizzard OAuth credentials (required) |
| `BLIZZARD_CLIENT_ID_2` / `_SECRET_2` | — | Secondary Blizzard credentials (auth pool) |
| `DB_POOL` | 130 | PostgreSQL connection pool size |
| `DB_HOST` / `DB_PORT` | localhost/5432 | PostgreSQL host/port |
| `WOW_BIS_DATABASE_PASSWORD` | — | Production DB password |
| `PVP_SYNC_BATCH_SIZE` | 50 | Characters per batch job |
| `PVP_SYNC_CONCURRENCY` | 15 | Fiber/thread concurrency in batch job |
| `PVP_SYNC_THREADS` | 8 | SolidQueue threads for character_sync workers |
| `PVP_CHARACTER_SYNC_PROCESSES` | 1 | Parallel OS processes per region character_sync queue; increase to 2–4 when jobs pile up |
| `PVP_LEADERBOARD_CONCURRENCY` | 10 | Concurrent leaderboard HTTP fetches |
| `PVP_BLIZZARD_RPS` | 95.0 | Blizzard API requests per second |
| `PVP_BLIZZARD_HOURLY_QUOTA` | 36,000 | Blizzard API hourly request cap |
| `PVP_PROCESSING_THREADS` | 3 | Threads for CPU-bound aggregation worker |
| `TELEGRAM_BOT_TOKEN` | — | Telegram Bot API token |
| `TELEGRAM_CHAT_ID` | — | Default chat for broadcast notifications |
| `TELEGRAM_ALLOWED_CHAT_IDS` | — | Comma-separated chat IDs allowed to send commands |
| `TELEGRAM_WEBHOOK_SECRET` | — | Secret token validated in `X-Telegram-Bot-Api-Secret-Token` header |

### Schema Highlights

- **JSONB columns**: `stats`, `sockets`, `crafting_stats`, `bonus_list` on `character_items`; `spec_equipment_fingerprints`, `spec_talent_loadout_codes`, `stat_pcts` on `characters`; `meta` on `translations`
- **Compressed bytea**: `raw_equipment`, `raw_specialization` on `pvp_leaderboard_entries` (zstd)
- **Soft deletion / staleness**: `unavailable_until`, `meta_synced_at`, `equipment_processed_at`, `specialization_processed_at`
- **Key indexes**: `(pvp_leaderboard_id, spec_id, rating)` on entries; `(name, realm, region)` unique on characters; `(bracket, spec_id)` on meta popularity tables
- **Fiber isolation**: `config.active_support.isolation_level = :fiber` (set in `application.rb`) prevents fiber DB connection corruption

### Admin & Monitoring

- Mission Control job UI: `/jobs`
- Avo admin panel: `/avo` — CRUD for all models; custom filters (spec_id, item_level, etc.); bulk Avo actions: `SyncLeaderboardsAction`, `SyncCharacterAction`, `BuildAggregationsAction`, `SyncTalentTreesAction`
- Custom admin dashboard: `/admin/dashboard` — DB, job queue, and cache health checks
- OpenAPI docs: `/api-docs` (UI) and `/api-docs/openapi.yaml`
- `JobPerformanceMonitor` records duration and success/failure for every job via `JobPerformanceMetric`
- Sentry integration (`sentry-rails`, `sentry-ruby`) for error tracking
- `rack-attack` — blocks scanner paths, throttles 120 req/min per IP (health check exempted)
- **Telegram Bot** — webhook at `POST /telegram/webhook` (secret header auth via `TELEGRAM_WEBHOOK_SECRET`). Commands: `/cycle [id]` (with inline buttons), `/progress`, `/history`, `/syncnow`, `/currentsync`, `/abort <id>`, `/errors`, `/jobs`. Auto-notifications: cycle milestones (25/50/75%), failed-character reports, stale-cycle alerts, deploy notifications (`rake telegram:notify_deploy` via `app.json` postdeploy). Chat IDs whitelisted via `TELEGRAM_ALLOWED_CHAT_IDS`.

### Testing

RSpec + FactoryBot + DatabaseCleaner (truncation between suite runs, transaction per test). Fixtures for Blizzard API responses live in `spec/fixtures/`. SimpleCov tracks coverage. `shoulda-matchers` and `faker` also available.

```bash
bundle exec rspec spec/jobs/
bundle exec rspec spec/services/pvp/
bundle exec rspec spec/requests/
```

### Key Gems

| Gem | Purpose |
|---|---|
| `rails ~> 8.1` | Framework |
| `pg ~> 1.6` | PostgreSQL adapter |
| `solid_queue/cache/cable` | PostgreSQL-backed jobs, cache, ActionCable |
| `oj ~> 3.16` | Fast JSON (replaces stdlib JSON globally) |
| `httpx ~> 1.6` | Concurrent HTTP client for Blizzard API |
| `async ~> 2.21` | Fiber-based concurrency |
| `avo` | Admin panel at `/avo` |
| `mission_control-jobs ~> 1.1` | Job monitoring UI at `/jobs` |
| `rack-attack ~> 6.7` | Request throttling/blocking |
| `sentry-rails/ruby` | Error tracking |
| `lograge ~> 0.14` | Single-line request logging |
| `puma ~> 7.1` + `thruster` | Web server |
| `steep` | Type checking (RBS) |
| `rubocop-rails-omakase` | Code style |
