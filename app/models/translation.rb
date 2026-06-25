# == Schema Information
#
# Table name: translations
# Database name: primary
#
#  id                :bigint           not null, primary key
#  embedding         :vector(1536)
#  key               :string           not null
#  locale            :string           not null
#  meta              :jsonb            not null
#  translatable_type :string           not null
#  value             :text             not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  translatable_id   :bigint           not null
#
# Indexes
#
#  index_translations_on_key                              (key)
#  index_translations_on_locale                           (locale)
#  index_translations_on_translatable                     (translatable_type,translatable_id)
#  index_translations_on_translatable_and_locale_and_key  (translatable_type,translatable_id,locale,key) UNIQUE
#  translations_embedding_idx                             (embedding) USING hnsw
#
class Translation < ApplicationRecord
  has_neighbors :embedding

  belongs_to :translatable, polymorphic: true

  validates :locale, :key, :value, :meta, presence: true

  scope :for_locale, ->(locale) { where(locale:) }
  scope :for_key,    ->(key)    { where(key:) }
  scope :for_translatable, ->(translatable) {
    where(translatable_type: translatable.class.name, translatable_id: translatable.id)
  }
  scope :talent_descriptions, -> {
    where(translatable_type: "Talent", key: "description", locale: "en_US")
      .where.not(value: [ nil, "" ])
  }
  scope :needs_embedding, -> { where(embedding: nil) }
end
