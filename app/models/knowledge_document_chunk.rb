# == Schema Information
#
# Table name: knowledge_document_chunks
# Database name: primary
#
#  id                    :bigint           not null, primary key
#  chunk_index           :integer          not null
#  content               :text             not null
#  embedding             :vector(1536)
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  knowledge_document_id :bigint           not null
#
# Indexes
#
#  idx_kd_chunks_on_doc_and_index           (knowledge_document_id,chunk_index) UNIQUE
#  knowledge_document_chunks_embedding_idx  (embedding) USING hnsw
#
# Foreign Keys
#
#  fk_rails_...  (knowledge_document_id => knowledge_documents.id)
#
class KnowledgeDocumentChunk < ApplicationRecord
  has_neighbors :embedding

  belongs_to :knowledge_document

  scope :needs_embedding, -> { where(embedding: nil) }
end
