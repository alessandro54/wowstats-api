# RAG Pipeline — TODO

## Context

Goal: enrich PvP meta insights with LLM-generated explanations ("why did Frost Mage trend up?").
Knowledge extraction is done — `KnowledgeDocument` + `SyncPatchNotesJob` are live.
Next phase: embed documents → vector search → LLM generation.

---

## Phase 1 — Item descriptions (2-line change, free signal)

Extend `EnsureMetaTranslationsJob#ensure_item_translations` to also store `data["description"]`
from the Blizzard Item API response (already fetched, just not persisted).
Most gear has no description, but trinkets/legendaries do — worth capturing.

---

## Phase 2 — Embeddings infrastructure

**Gem:** `neighbor` (pgvector wrapper for ActiveRecord) — already on Postgres, no new infra.

```ruby
gem "neighbor"
```

**Migration:** add `embedding` column to `knowledge_documents` + `translations`.

```ruby
add_column :knowledge_documents, :embedding, :vector, limit: 1536
add_column :translations, :embedding, :vector, limit: 1536
add_index :knowledge_documents, :embedding, using: :ivfflat,
          opclass: :vector_cosine_ops, with: { lists: 100 }
```

**What to embed:**
- `knowledge_documents.content` (patch notes, hotfixes) — embed full doc or chunk by date section
- `translations WHERE key = 'description' AND translatable_type = 'Talent'` — talent ability descriptions
- Meta snapshot summaries (generated text) — "3v3 Frost Mage: [Item X] ↑87% (+14pp vs last week)"

**Embedding model:** Claude (`claude-embed-*`) or OpenAI `text-embedding-3-small` (1536 dims).
Decide before building — dimension must match `vector(N)` column.

---

## Phase 3 — Embed jobs

`EmbedKnowledgeDocumentsJob` — for each unfetched/stale `KnowledgeDocument`, call embedding API,
store vector. Run after `SyncPatchNotesJob`.

`EmbedTalentDescriptionsJob` — embed talent descriptions from `translations`.

`EmbedMetaSnapshotsJob` — generate text summaries from `pvp_meta_*_popularity` rows,
embed, store in a new `pvp_meta_embeddings` table or directly on the popularity models.

---

## Phase 4 — Retrieval service

```ruby
# app/services/rag/retrieve_context_service.rb
# Input: query string (e.g. "why is frost mage strong in 3v3")
# Output: top-K relevant document chunks
```

Use `neighbor` cosine similarity search:
```ruby
KnowledgeDocument.nearest_neighbors(:embedding, query_vector, distance: "cosine").limit(5)
```

---

## Phase 5 — Generation endpoint

New controller: `GET /api/v1/pvp/meta/insights/explain?spec=frost_mage&bracket=3v3`

Flow:
1. Build query from spec + bracket + current meta snapshot
2. Retrieve top-K chunks (patch notes + talent descriptions)
3. Construct prompt with context
4. Call Claude API → stream or return narrative
5. Cache result (invalidate on next sync cycle)

---

## Phase 6 — Scheduling

Add `SyncPatchNotesJob` to mission_control / solid_queue schedule (daily, after leaderboard sync).
Add `EmbedKnowledgeDocumentsJob` as a callback after `SyncPatchNotesJob` completes.

---

## Open decisions

- Embedding provider (Claude vs OpenAI) — affects gem + dimension
- Chunk strategy for patch notes: embed whole article vs split by date section
- Whether to expose generation as streaming SSE or standard JSON
- Cache TTL for generated insights (suggest: 1 sync cycle = ~4h)
