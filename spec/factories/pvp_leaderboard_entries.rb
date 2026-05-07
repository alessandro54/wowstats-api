# spec/factories/pvp_leaderboard_entries.rb
# == Schema Information
#
# Table name: pvp_leaderboard_entries
# Database name: primary
#
#  id                          :bigint           not null, primary key
#  equipment_processed_at      :datetime
#  hero_talent_tree_name       :string
#  item_level                  :integer
#  losses                      :integer          default(0)
#  rank                        :integer
#  rating                      :integer
#  snapshot_at                 :datetime
#  specialization_processed_at :datetime
#  sync_retry_count            :integer          default(0), not null
#  tier_4p_active              :boolean          default(FALSE)
#  tier_set_name               :string
#  tier_set_pieces             :integer
#  wins                        :integer          default(0)
#  created_at                  :datetime         not null
#  updated_at                  :datetime         not null
#  character_id                :bigint           not null
#  hero_talent_tree_id         :integer
#  pvp_leaderboard_id          :bigint           not null
#  spec_id                     :integer
#  tier_set_id                 :integer
#
# Indexes
#
#  idx_entries_for_talent_player_count                     (pvp_leaderboard_id,spec_id,character_id) WHERE (specialization_processed_at IS NOT NULL)
#  idx_entries_top_chars_equipment                         (pvp_leaderboard_id,character_id,rating DESC) WHERE ((spec_id IS NOT NULL) AND (equipment_processed_at IS NOT NULL))
#  idx_entries_top_chars_specialization                    (pvp_leaderboard_id,character_id,rating DESC) WHERE ((spec_id IS NOT NULL) AND (specialization_processed_at IS NOT NULL))
#  idx_entries_unique_char_leaderboard                     (character_id,pvp_leaderboard_id) UNIQUE
#  index_entries_for_batch_processing                      (id,equipment_processed_at)
#  index_entries_for_spec_meta                             (pvp_leaderboard_id,spec_id,rating)
#  index_entries_on_leaderboard_and_rating                 (pvp_leaderboard_id,rating)
#  index_pvp_entries_on_character_and_equipment_processed  (character_id,equipment_processed_at) WHERE (equipment_processed_at IS NOT NULL)
#  index_pvp_leaderboard_entries_on_character_id           (character_id)
#  index_pvp_leaderboard_entries_on_hero_talent_tree_id    (hero_talent_tree_id)
#  index_pvp_leaderboard_entries_on_pvp_leaderboard_id     (pvp_leaderboard_id)
#  index_pvp_leaderboard_entries_on_rank                   (rank)
#  index_pvp_leaderboard_entries_on_tier_set_id            (tier_set_id)
#
# Foreign Keys
#
#  fk_rails_...  (character_id => characters.id)
#  fk_rails_...  (pvp_leaderboard_id => pvp_leaderboards.id)
#
FactoryBot.define do
  factory :pvp_leaderboard_entry do
    association :pvp_leaderboard
    association :character

    rank      { Faker::Number.between(from: 1, to: 3000) }
    rating    { Faker::Number.between(from: 1200, to: 3500) }
    wins      { 0 }
    losses    { 0 }
    sync_retry_count { 0 }
    snapshot_at { Time.current }

    item_level { Faker::Number.between(from: 450, to: 700) }

    spec_id { Faker::Number.between(from: 1, to: 50) }

    hero_talent_tree_id   { Faker::Number.between(from: 1, to: 20) }
    hero_talent_tree_name { Faker::Games::DnD.klass.downcase }

    tier_set_id           { Faker::Number.between(from: 1, to: 20) }
    tier_set_name         { "Set #{tier_set_id}" }
    tier_set_pieces       { 0 }
    tier_4p_active        { false }

    trait :with_gear do
      character_name = %w[egirlbooster jw motívate].sample
      raw_equipment do
        JSON.parse(
          File.read(
            Rails.root.join("spec/fixtures/equipment/#{character_name}.json")
          )
        )
      end

      raw_specialization do
        JSON.parse(
          File.read(
            Rails.root.join("spec/fixtures/specialization/#{character_name}.json")
          )
        )
      end
    end
  end
end
