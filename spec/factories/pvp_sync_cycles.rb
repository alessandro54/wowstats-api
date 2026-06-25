# == Schema Information
#
# Table name: pvp_sync_cycles
# Database name: primary
#
#  id                          :bigint           not null, primary key
#  completed_at                :datetime
#  completed_character_batches :integer          default(0), not null
#  expected_character_batches  :integer          default(0), not null
#  regions                     :string           default([]), not null, is an Array
#  snapshot_at                 :datetime         not null
#  status                      :string           default("syncing_leaderboards"), not null
#  created_at                  :datetime         not null
#  updated_at                  :datetime         not null
#  pvp_season_id               :bigint           not null
#  telegram_message_id         :bigint
#
# Indexes
#
#  index_pvp_sync_cycles_on_pvp_season_id             (pvp_season_id)
#  index_pvp_sync_cycles_on_pvp_season_id_and_status  (pvp_season_id,status)
#
# Foreign Keys
#
#  fk_rails_...  (pvp_season_id => pvp_seasons.id)
#
FactoryBot.define do
  factory :pvp_sync_cycle do
    association :pvp_season
    status { "syncing_characters" }
    snapshot_at { Time.current }
    regions { [ "us" ] }
    expected_character_batches { 0 }
    completed_character_batches { 0 }
  end
end
