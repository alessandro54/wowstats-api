require "rails_helper"

RSpec.describe "GET /api/v1/characters/:region/:realm/:name/trends", type: :request do
  let(:season)      { create(:pvp_season) }
  let(:leaderboard) { create(:pvp_leaderboard, pvp_season: season, bracket: "3v3", region: "us") }
  let(:char)        { create(:character, region: "us", realm: "tichondrius", name: "alpha") }

  before do
    create(:pvp_leaderboard_entry_snapshot,
           character: char, pvp_leaderboard: leaderboard,
           snapshot_at: 6.hours.ago,
           rank: 5, rating: 2810, wins: 42, losses: 18)
    create(:pvp_leaderboard_entry_snapshot,
           character: char, pvp_leaderboard: leaderboard,
           snapshot_at: 30.hours.ago,
           rank: 8, rating: 2778, wins: 38, losses: 16)
    # Outside 7d window — should be filtered out
    create(:pvp_leaderboard_entry_snapshot,
           character: char, pvp_leaderboard: leaderboard,
           snapshot_at: 10.days.ago,
           rank: 50, rating: 2400, wins: 5, losses: 1)
  end

  it "returns trend snapshots grouped by bracket within the 7d window" do
    get "/api/v1/characters/us/tichondrius/alpha/trends"
    expect(response).to have_http_status(:ok)

    body = response.parsed_body
    expect(body["character"]).to include("name" => "alpha", "realm" => "tichondrius", "region" => "us")
    expect(body["trends"].size).to eq(1)

    trend = body["trends"].first
    expect(trend["bracket"]).to eq("3v3")
    expect(trend["snapshots"].size).to eq(2)
    expect(trend["snapshots"].first["rating"]).to eq(2778) # ascending by snapshot_at
    expect(trend["snapshots"].last["rating"]).to eq(2810)
  end

  it "404s for unknown character" do
    get "/api/v1/characters/us/tichondrius/missing/trends"
    expect(response).to have_http_status(:not_found)
  end
end
