# frozen_string_literal: true

require "rails_helper"

RSpec.describe Pvp::Leaderboards::LeaderboardDeltasQuery do
  let(:season)      { create(:pvp_season) }
  let(:leaderboard) { create(:pvp_leaderboard, pvp_season: season, bracket: "3v3", region: "us") }
  let(:char_a)      { create(:character) }
  let(:char_b)      { create(:character) }
  let(:char_c)      { create(:character) }

  before do
    # 30h-old snapshot for A — inside 24-48h window → baseline
    create(:pvp_leaderboard_entry_snapshot,
           character: char_a, pvp_leaderboard: leaderboard,
           snapshot_at: 30.hours.ago,
           rank: 100, rating: 2400, wins: 40, losses: 30)
    # 12h-old for A — outside window (too recent)
    create(:pvp_leaderboard_entry_snapshot,
           character: char_a, pvp_leaderboard: leaderboard,
           snapshot_at: 12.hours.ago,
           rank: 50, rating: 2600, wins: 50, losses: 32)

    # 6d-old for B — outside window (too stale)
    create(:pvp_leaderboard_entry_snapshot,
           character: char_b, pvp_leaderboard: leaderboard,
           snapshot_at: 6.days.ago,
           rank: 200, rating: 2200, wins: 10, losses: 5)

    # No snapshots for C
  end

  it "returns the most-recent snapshot at-or-before 24h ago, capped at 48h" do
    deltas = described_class.new(leaderboard.id).call

    expect(deltas[char_a.id]).to include(rank: 100, rating: 2400, wins: 40, losses: 30)
    expect(deltas[char_b.id]).to be_nil
    expect(deltas[char_c.id]).to be_nil
  end

  it "scopes to the requested leaderboard" do
    other_lb = create(:pvp_leaderboard, pvp_season: season, bracket: "2v2", region: "us")
    create(:pvp_leaderboard_entry_snapshot,
           character: char_a, pvp_leaderboard: other_lb,
           snapshot_at: 30.hours.ago,
           rank: 999, rating: 9999, wins: 0, losses: 0)

    deltas = described_class.new(leaderboard.id).call
    expect(deltas[char_a.id][:rank]).to eq(100)
  end
end
