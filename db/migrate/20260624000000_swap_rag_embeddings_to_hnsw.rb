class SwapRagEmbeddingsToHnsw < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # The original ivfflat indexes were created in the same migration that added
  # the (initially NULL) embedding columns, so ivfflat trained its centroids on
  # zero vectors and never recovered after backfill. HNSW needs no training pass,
  # gives better recall, and at this data scale (a few thousand embedded rows)
  # needs no lists/probes tuning.
  def up
    execute "DROP INDEX CONCURRENTLY IF EXISTS knowledge_documents_embedding_idx"
    execute "DROP INDEX CONCURRENTLY IF EXISTS translations_embedding_idx"

    execute <<~SQL
      CREATE INDEX CONCURRENTLY knowledge_documents_embedding_idx
        ON knowledge_documents USING hnsw (embedding vector_cosine_ops)
    SQL
    execute <<~SQL
      CREATE INDEX CONCURRENTLY translations_embedding_idx
        ON translations USING hnsw (embedding vector_cosine_ops)
    SQL
  end

  def down
    execute "DROP INDEX CONCURRENTLY IF EXISTS knowledge_documents_embedding_idx"
    execute "DROP INDEX CONCURRENTLY IF EXISTS translations_embedding_idx"

    execute <<~SQL
      CREATE INDEX CONCURRENTLY knowledge_documents_embedding_idx
        ON knowledge_documents USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100)
    SQL
    execute <<~SQL
      CREATE INDEX CONCURRENTLY translations_embedding_idx
        ON translations USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100)
    SQL
  end
end
