require "rails_helper"

RSpec.describe Pvp::PruneLeaderboardSnapshotsJob, type: :job do
  let(:leaderboard) { create(:pvp_leaderboard) }
  let(:char)        { create(:character) }

  before do
    create(:pvp_leaderboard_entry_snapshot,
           character: char, pvp_leaderboard: leaderboard,
           snapshot_at: 8.days.ago)
    create(:pvp_leaderboard_entry_snapshot,
           character: char, pvp_leaderboard: leaderboard,
           snapshot_at: 6.days.ago)
    create(:pvp_leaderboard_entry_snapshot,
           character: char, pvp_leaderboard: leaderboard,
           snapshot_at: 1.hour.ago)
  end

  it "deletes snapshots older than 7 days" do
    expect {
      described_class.new.perform
    }.to change { PvpLeaderboardEntrySnapshot.count }.from(3).to(2)
  end

  it "leaves rows newer than the cutoff intact" do
    described_class.new.perform
    remaining = PvpLeaderboardEntrySnapshot.pluck(:snapshot_at)
    remaining.each { |t| expect(t).to be > 7.days.ago }
  end
end
