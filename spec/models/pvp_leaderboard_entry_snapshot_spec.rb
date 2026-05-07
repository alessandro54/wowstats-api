# == Schema Information
#
# Table name: pvp_leaderboard_entry_snapshots
# Database name: primary
#
#  id                 :bigint           not null, primary key
#  losses             :integer          not null
#  rank               :integer          not null
#  rating             :integer          not null
#  snapshot_at        :datetime         not null
#  wins               :integer          not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  character_id       :bigint           not null
#  pvp_leaderboard_id :bigint           not null
#  pvp_sync_cycle_id  :bigint
#  spec_id            :integer
#
# Indexes
#
#  idx_snap_character_time                                      (character_id,snapshot_at DESC)
#  idx_snap_leaderboard_time                                    (pvp_leaderboard_id,snapshot_at DESC)
#  idx_snap_unique                                              (character_id,pvp_leaderboard_id,snapshot_at) UNIQUE
#  index_pvp_leaderboard_entry_snapshots_on_character_id        (character_id)
#  index_pvp_leaderboard_entry_snapshots_on_pvp_leaderboard_id  (pvp_leaderboard_id)
#  index_pvp_leaderboard_entry_snapshots_on_pvp_sync_cycle_id   (pvp_sync_cycle_id)
#
# Foreign Keys
#
#  fk_rails_...  (character_id => characters.id)
#  fk_rails_...  (pvp_leaderboard_id => pvp_leaderboards.id)
#  fk_rails_...  (pvp_sync_cycle_id => pvp_sync_cycles.id)
#
require "rails_helper"

RSpec.describe PvpLeaderboardEntrySnapshot, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:character) }
    it { is_expected.to belong_to(:pvp_leaderboard) }
    it { is_expected.to belong_to(:pvp_sync_cycle).optional }
  end

  describe "validations" do
    subject { build(:pvp_leaderboard_entry_snapshot) }

    it { is_expected.to validate_presence_of(:snapshot_at) }
    it { is_expected.to validate_presence_of(:rank) }
    it { is_expected.to validate_presence_of(:rating) }
    it { is_expected.to validate_presence_of(:wins) }
    it { is_expected.to validate_presence_of(:losses) }
  end

  describe "uniqueness" do
    it "rejects duplicate (character, leaderboard, snapshot_at)" do
      existing = create(:pvp_leaderboard_entry_snapshot)
      dup = build(
        :pvp_leaderboard_entry_snapshot,
        character:       existing.character,
        pvp_leaderboard: existing.pvp_leaderboard,
        snapshot_at:     existing.snapshot_at
      )
      expect { dup.save!(validate: false) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end
  end
end
