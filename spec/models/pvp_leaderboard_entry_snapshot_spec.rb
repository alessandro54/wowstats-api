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
