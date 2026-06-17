# WoW Stats — PvP Meta API

> Real-time World of Warcraft PvP analytics. Ingests live Blizzard leaderboard data for US and EU regions, aggregates it into gear/talent/enchant meta statistics, and serves the results as a low-latency JSON API powering [wowstats.gg](https://wowstats.gg).

---

## Motivation

The official Blizzard Armory shows individual character snapshots. It doesn't answer the question every PvP player actually asks: *what are the top-rated players in my bracket running right now?*

This project answers that by continuously scraping the top-1000 leaderboard entries per bracket, resolving every character's live equipment and talent loadout, and aggregating it into statistical rankings — item popularity, enchant adoption, talent node usage, stat distribution — updated on every sync cycle.

The same data pipeline feeds a RAG endpoint: patch notes are fetched from Blizzard's news API, chunked, and embedded with OpenAI's `text-embedding-3-small`. Cosine similarity search over pgvector retrieves the most relevant context for any spec/bracket combination, which Claude then synthesizes into a human-readable meta explanation.

---

## Stack

| Layer | Technology |
|---|---|
| **API** | Rails 8.1 (API-only), Ruby 4.0 |
| **Database** | PostgreSQL 18 + pgvector (IVFFlat) |
| **Jobs** | SolidQueue (PostgreSQL-backed, no Redis) |
| **Cache** | SolidCache (PostgreSQL-backed, no Redis) |
| **Embeddings** | OpenAI `text-embedding-3-small` (1536 dims) |
| **Generation** | Anthropic Claude (configurable via `ANTHROPIC_MODEL`) |
| **Type checking** | Steep + RBS |
| **Linting** | RuboCop Rails |
| **Testing** | RSpec |
| **Infra** | Dokku, Cloudflare |
| **Ops** | Telegram bot (sync visibility + manual triggers) |

No Redis. No Sidekiq. No Elasticsearch. Everything runs on PostgreSQL.

---

## Architecture

```
Blizzard API  (US + EU)
      │
      │  OAuth2 token pool — dual credentials, 95 req/s token-bucket rate limiter
      ▼
SyncCurrentSeasonLeaderboardsJob          Phase 1 — discover brackets
      │  parallel HTTP per region
      ▼
SyncBracketJob ×N                         Phase 2 — fetch leaderboard pages
      │  stores raw rankings + snapshots
      ▼
SyncCharacterBatchJob ×N                  Phase 3 — resolve characters
      │  threaded (15 threads/job), region-isolated queues
      │  fetches equipment + talent loadouts per character
      │  guard: skips talent writes when loadout code unchanged
      ▼
BuildAggregationsJob                      Phase 4 — compute meta
      │  triggered atomically when all batches complete
      │  top-N filtering, per-slot item ranking, talent node stats
      ▼
PostgreSQL  (pvp_meta_* tables)
      │
      ├──▶  JSON API  /api/v1/pvp/meta/*     (SolidCache, versioned cache keys)
      │
      └──▶  RAG Pipeline
               │
               ├── SyncPatchNotesJob         daily — Blizzard news → KnowledgeDocuments
               ├── EmbedKnowledgeDocumentsJob → OpenAI embeddings → pgvector
               ├── EmbedTalentDescriptionsJob → OpenAI embeddings → pgvector
               │
               └── /api/v1/pvp/meta/insights/explain
                        cosine similarity search (IVFFlat)
                        → Claude generation
                        → 4h cached response
```

### Key design decisions

**All-in-PostgreSQL** — SolidQueue replaces Sidekiq; SolidCache replaces Redis. One fewer operational dependency, ACID guarantees on job state, and `SKIP LOCKED` for queue fairness.

**Region-isolated queues** — US and EU character batches enqueue into separate named queues so a slow EU run can't starve US processing.

**Threaded batch jobs** — each `SyncCharacterBatchJob` spawns a configurable thread pool (default 15) to fan out HTTP requests to Blizzard. Bounded by a token-bucket rate limiter shared across threads.

**Dual credential pool** — two Blizzard OAuth client pairs rotate across requests to maximise effective throughput without exceeding per-credential limits.

**Talent write guard** — `talent_loadout_code` is stored per character; talent rows are only written when the code actually changes, cutting write amplification on unchanged characters.

**Versioned cache keys** — all meta endpoints share a `META_CACHE_VERSION` counter in SolidCache. A single increment busts every cached response simultaneously, used after each aggregation cycle.

**pgvector IVFFlat** — embeddings are indexed with `lists=100` approximate nearest-neighbor for cosine similarity, created concurrently to avoid locking the table.

---

## API Endpoints

All endpoints return JSON. No authentication required.

```
GET /up                                             Health check

GET /api/v1/pvp/meta/items?bracket=&spec_id=        Item popularity by slot
GET /api/v1/pvp/meta/enchants?bracket=&spec_id=     Enchant adoption rates
GET /api/v1/pvp/meta/gems?bracket=&spec_id=         Gem usage
GET /api/v1/pvp/meta/talents?bracket=&spec_id=      Talent node statistics
GET /api/v1/pvp/meta/specs?bracket=                 Spec distribution
GET /api/v1/pvp/meta/specs/:id?bracket=             Single spec detail
GET /api/v1/pvp/meta/class_distribution?bracket=    Class tier breakdown
GET /api/v1/pvp/meta/stat_priority?bracket=&spec_id= Median stat distribution
GET /api/v1/pvp/meta/top_players?bracket=&spec_id=  Top-rated players
GET /api/v1/pvp/meta/insights/explain?bracket=&spec_id= AI meta explanation (RAG)

GET /api/v1/characters                              Character list
GET /api/v1/pvp/leaderboard_entry_snapshots         Rating trend snapshots
```

---

## Prerequisites

- Ruby 4.0.1 (via [rbenv](https://github.com/rbenv/rbenv) or [mise](https://mise.jdx.dev))
- PostgreSQL 14+ with [pgvector](https://github.com/pgvector/pgvector)
- Bundler

```bash
# macOS (pgvector via brew)
brew install postgresql pgvector

# Ubuntu
apt install postgresql-16 postgresql-16-pgvector
```

---

## Local Setup

```bash
git clone https://github.com/alessandro54/wowstats-api
cd wowstats-api
bundle install

cp .env.example .env
# edit .env — set BLIZZARD_CLIENT_ID + BLIZZARD_CLIENT_SECRET at minimum

bundle exec rails db:create db:migrate
bundle exec rails server          # API on :3000

# In a second terminal — required to run jobs
bundle exec rails solid_queue:start
```

---

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `BLIZZARD_CLIENT_ID` | — | **Required.** Blizzard OAuth client ID |
| `BLIZZARD_CLIENT_SECRET` | — | **Required.** Blizzard OAuth client secret |
| `BLIZZARD_CLIENT_ID_2` | — | Second credential for auth pool |
| `BLIZZARD_CLIENT_SECRET_2` | — | Second credential secret |
| `OPENAI_API_KEY` | — | Required for embedding jobs |
| `ANTHROPIC_API_KEY` | — | Required for insights endpoint |
| `ANTHROPIC_MODEL` | `claude-opus-4-8` | Override generation model per-environment |
| `DB_HOST` | `localhost` | PostgreSQL host |
| `DB_PORT` | `5432` | PostgreSQL port |
| `DB_POOL` | `130` | Connection pool size |
| `PVP_SYNC_BATCH_SIZE` | `50` | Characters per batch job |
| `PVP_SYNC_CONCURRENCY` | `15` | Threads per batch job |
| `PVP_SYNC_THREADS` | `8` | SolidQueue threads for sync workers |
| `PVP_BLIZZARD_RPS` | `95.0` | Blizzard API token-bucket rate (req/s) |
| `PVP_BLIZZARD_HOURLY_QUOTA` | `36000` | Blizzard API hourly cap |
| `PVP_META_TOP_N` | `1000` | Top-N entries used in aggregations |
| `RAILS_MAX_THREADS` | `3` | Puma thread count |
| `TELEGRAM_BOT_TOKEN` | — | Telegram Bot API token |
| `TELEGRAM_CHAT_ID` | — | Default broadcast chat |
| `TELEGRAM_ALLOWED_CHAT_IDS` | — | Comma-separated allowed chat IDs |
| `TELEGRAM_WEBHOOK_SECRET` | — | Webhook auth token |

---

## Running a Sync

```bash
bundle exec rails console

# Seed a season (required once)
PvpSeason.create!(name: "TWW Season 2", blizzard_id: 38, is_current: true, display_name: "TWW S2")

# Full sync — all brackets, US + EU
Pvp::SyncCurrentSeasonLeaderboardsJob.perform_later

# Single bracket (ad-hoc)
Pvp::SyncBracketJob.perform_later(region: "us", season: PvpSeason.current, bracket: "3v3")

# Seed RAG knowledge base
SyncPatchNotesJob.perform_later
EmbedKnowledgeDocumentsJob.perform_later
EmbedTalentDescriptionsJob.perform_later
```

---

## Tests & Quality

```bash
bundle exec rspec                           # full suite
bundle exec rspec spec/requests/            # API integration specs
bundle exec rspec spec/services/pvp/        # service unit specs
bundle exec rspec spec/jobs/                # job specs

bundle exec rubocop                         # lint
bundle exec rubocop --autocorrect           # auto-fix
bundle exec steep check                     # type check (RBS)
```

CI (GitHub Actions) runs lint + type check + full test suite on every PR. The test job uses `pgvector/pgvector:pg15` as the PostgreSQL service so vector extension is available without manual setup.

---

## Admin & Ops

- **Job monitor** — `/jobs` (Mission Control UI for SolidQueue)
- **Admin panel** — `/avo` (Avo resource management)

### Telegram Bot

Register the webhook once after deploy:

```bash
curl "https://api.telegram.org/bot<TOKEN>/setWebhook?url=https://api.wowstats.gg/telegram/webhook&secret_token=<SECRET>"
```

| Command | Description |
|---|---|
| `/cycle [id]` | Last (or specific) sync cycle status with action buttons |
| `/progress` | Live batch progress bar + ETA |
| `/history` | Last 5 completed cycles with duration |
| `/syncnow` | Trigger an immediate sync |
| `/abort <id>` | Abort a running cycle |
| `/errors` | Job errors in the last 24h |
| `/jobs` | Job success rate summary |

Auto-notifications fire at 25/50/75% sync progress, on failed-character rate >5%, on stale cycles (stuck >2h), and on every Dokku deploy.

---

## Project Structure

```
app/
  controllers/api/v1/pvp/meta/   # meta endpoints (items, talents, insights…)
  jobs/pvp/                      # sync pipeline jobs
  jobs/                          # embed jobs, patch note sync
  models/                        # Character, CharacterItem, Translation, KnowledgeDocument…
  services/
    blizzard/                    # API client, rate limiter, character fetcher, news sync
    pvp/meta/                    # aggregation services
    rag/                         # EmbeddingService, RetrieveContextService, GenerateInsightService
  telegram/                      # bot command handlers

db/
  migrate/                       # incremental schema migrations
  schema.rb

spec/
  requests/                      # API integration specs
  services/                      # unit specs
  jobs/                          # job specs
```
