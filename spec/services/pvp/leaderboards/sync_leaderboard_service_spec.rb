require "rails_helper"

RSpec.describe Pvp::Leaderboards::SyncLeaderboardService, type: :service do
  let(:season)  { create(:pvp_season, blizzard_id: 42) }
  let(:cycle)   { create(:pvp_sync_cycle, pvp_season: season) }
  let(:bracket) { "3v3" }
  let(:region)  { "us" }
  let(:snapshot_at) { Time.current.change(usec: 0) }

  let(:blizzard_response) do
    {
      "entries" => [
        {
          "character" => {
            "id" => 100,
            "name" => "Alpha",
            "realm" => { "slug" => "tichondrius" }
          },
          "rank" => 1, "rating" => 2800,
          "season_match_statistics" => { "won" => 50, "lost" => 20 }
        }
      ]
    }
  end

  before do
    allow(Blizzard::Api::GameData::PvpSeason::Leaderboard)
      .to receive(:fetch)
      .with(hash_including(bracket: "3v3", region: "us"))
      .and_return(blizzard_response)
  end

  describe "snapshot writes" do
    it "writes a snapshot row per entry with matching snapshot_at and cycle id" do
      expect {
        described_class.call(season:, bracket:, region:, snapshot_at:, sync_cycle_id: cycle.id)
      }.to change { PvpLeaderboardEntrySnapshot.count }.by(1)

      snap = PvpLeaderboardEntrySnapshot.last
      expect(snap.snapshot_at).to be_within(1.second).of(snapshot_at)
      expect(snap.rank).to eq(1)
      expect(snap.rating).to eq(2800)
      expect(snap.wins).to eq(50)
      expect(snap.losses).to eq(20)
      expect(snap.pvp_sync_cycle_id).to eq(cycle.id)
    end

    it "is idempotent on replay (same snapshot_at)" do
      described_class.call(season:, bracket:, region:, snapshot_at:, sync_cycle_id: cycle.id)
      expect {
        described_class.call(season:, bracket:, region:, snapshot_at:, sync_cycle_id: cycle.id)
      }.not_to change { PvpLeaderboardEntrySnapshot.count }
    end

    it "isolates snapshot failures from primary entry writes" do
      allow(PvpLeaderboardEntrySnapshot).to receive(:insert_all).and_raise(StandardError, "snapshot boom")
      allow(Sentry).to receive(:capture_exception)

      result = described_class.call(season:, bracket:, region:, snapshot_at:, sync_cycle_id: cycle.id)

      expect(result).to be_success
      expect(PvpLeaderboardEntry.count).to eq(1)
      expect(PvpLeaderboardEntrySnapshot.count).to eq(0)
      expect(Sentry).to have_received(:capture_exception)
    end
  end
end
