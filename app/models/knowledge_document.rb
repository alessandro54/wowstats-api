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
#  knowledge_documents_embedding_idx                    (embedding) USING ivfflat
#
class KnowledgeDocument < ApplicationRecord
  has_neighbors :embedding

  RELEVANT_TITLE_RE = /hotfix|patch notes|update notes|class tuning|pvp tuning/i

  validates :source, :external_id, :title, :url, presence: true
  validates :external_id, uniqueness: { scope: :source }

  scope :blizzard_news,    -> { where(source: "blizzard_news") }
  scope :stale,            -> { where(fetched_at: nil).or(where("external_updated_at > fetched_at")) }
  scope :needs_embedding,  -> { where(embedding: nil).where.not(content: [ nil, "" ]) }

  def stale?
    fetched_at.nil? || (external_updated_at && external_updated_at > fetched_at)
  end

  def fetched?
    fetched_at.present? && content.present?
  end
end
