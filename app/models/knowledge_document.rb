# == Schema Information
#
# Table name: knowledge_documents
# Database name: primary
#
#  id                  :bigint           not null, primary key
#  category            :string
#  content             :text
#  embedding           :vector(1536)
#  external_updated_at :datetime
#  fetched_at          :datetime
#  metadata            :jsonb            not null
#  published_at        :datetime
#  source              :string           not null
#  title               :string           not null
#  url                 :string           not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  external_id         :string           not null
#
# Indexes
#
#  index_knowledge_documents_on_external_updated_at     (external_updated_at)
#  index_knowledge_documents_on_fetched_at              (fetched_at)
#  index_knowledge_documents_on_source_and_external_id  (source,external_id) UNIQUE
#  knowledge_documents_embedding_idx                    (embedding) USING hnsw
#
class KnowledgeDocument < ApplicationRecord
  has_neighbors :embedding

  has_many :chunks, class_name: "KnowledgeDocumentChunk", dependent: :delete_all

  RELEVANT_TITLE_RE = /hotfix|patch notes|update notes|class tuning|pvp tuning/i

  # Patch notes run tens of KB; a single embedding over the whole doc has no
  # semantic resolution. Split into overlapping windows so each chunk embeds a
  # focused slice and the overlap avoids cutting a section across a boundary.
  CHUNK_SIZE    = 1_500
  CHUNK_OVERLAP = 200

  validates :source, :external_id, :title, :url, presence: true
  validates :external_id, uniqueness: { scope: :source }

  scope :blizzard_news,    -> { where(source: "blizzard_news") }
  scope :stale,            -> { where(fetched_at: nil).or(where("external_updated_at > fetched_at")) }
  scope :needs_embedding,  -> { where(embedding: nil).where.not(content: [ nil, "" ]) }
  scope :needs_chunking,   -> {
    where.not(content: [ nil, "" ]).where.missing(:chunks)
  }

  def stale?
    fetched_at.nil? || (external_updated_at && external_updated_at > fetched_at)
  end

  def fetched?
    fetched_at.present? && content.present?
  end

  # Replaces this document's chunks with freshly split windows (without
  # embeddings — EmbedKnowledgeDocumentsJob fills those in). Returns the chunks.
  def rebuild_chunks!
    windows = split_into_windows(content.to_s)
    transaction do
      chunks.delete_all
      windows.each_with_index.map do |text, idx|
        chunks.create!(chunk_index: idx, content: text)
      end
    end
  end

  private

    def split_into_windows(text)
      return [] if text.blank?

      step    = CHUNK_SIZE - CHUNK_OVERLAP
      windows = []
      offset  = 0
      while offset < text.length
        windows << text[offset, CHUNK_SIZE]
        offset += step
      end
      windows
    end
end
