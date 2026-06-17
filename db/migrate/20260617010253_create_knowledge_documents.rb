class CreateKnowledgeDocuments < ActiveRecord::Migration[8.1]
  def change
    create_table :knowledge_documents do |t|
      t.string   :source,               null: false
      t.string   :external_id,          null: false
      t.string   :title,                null: false
      t.string   :url,                  null: false
      t.text     :content
      t.string   :category
      t.datetime :published_at
      t.datetime :external_updated_at
      t.datetime :fetched_at
      t.jsonb    :metadata,             null: false, default: {}
      t.timestamps
    end

    add_index :knowledge_documents, [ :source, :external_id ], unique: true
    add_index :knowledge_documents, :external_updated_at
    add_index :knowledge_documents, :fetched_at
  end
end
