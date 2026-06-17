class AddEmbeddingsToRagTables < ActiveRecord::Migration[8.1]
  def up
    enable_extension "vector"

    add_column :knowledge_documents, :embedding, :vector, limit: 1536
    add_column :translations, :embedding, :vector, limit: 1536

    # IVFFlat approximate nearest-neighbor index for knowledge documents.
    # lists=100 is appropriate for tables up to ~1M rows.
    execute "CREATE INDEX ON knowledge_documents USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100)"
    execute "CREATE INDEX ON translations USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100)"
  end

  def down
    execute "DROP INDEX IF EXISTS knowledge_documents_embedding_idx"
    execute "DROP INDEX IF EXISTS translations_embedding_idx"
    remove_column :translations, :embedding
    remove_column :knowledge_documents, :embedding
  end
end
