class CreateKnowledgeDocumentChunks < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    create_table :knowledge_document_chunks do |t|
      t.references :knowledge_document, null: false, foreign_key: true, index: false
      t.integer :chunk_index, null: false
      t.text :content, null: false
      t.column :embedding, :vector, limit: 1536
      t.timestamps
    end

    add_index :knowledge_document_chunks,
              %i[knowledge_document_id chunk_index],
              unique: true,
              name:   "idx_kd_chunks_on_doc_and_index"

    execute <<~SQL
      CREATE INDEX CONCURRENTLY knowledge_document_chunks_embedding_idx
        ON knowledge_document_chunks USING hnsw (embedding vector_cosine_ops)
    SQL
  end

  def down
    drop_table :knowledge_document_chunks
  end
end
