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
FactoryBot.define do
  factory :translation do
    locale { "en_US" }
    key { "name" }
    value { "MyText" }
    meta { { "source" => "test" } }

    # Polymorphic association - default to Item
    association :translatable, factory: :item
  end
end
