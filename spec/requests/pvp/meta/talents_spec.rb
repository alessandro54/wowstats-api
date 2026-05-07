require "rails_helper"

RSpec.describe "GET /api/v1/pvp/meta/talents", type: :request do
  let(:season) { create(:pvp_season, is_current: true) }
  let(:spec_id) { 71 }
  let(:bracket) { "2v2" }
  let(:talent)  { create(:talent, node_id: 100, talent_type: "spec") }

  before do
    season # ensure season exists before request
    create(:talent_spec_assignment, talent: talent, spec_id: spec_id)
  end

  def get_talents
    get "/api/v1/pvp/meta/talents", params: { bracket: bracket, spec_id: spec_id }
  end

  context "with high confidence data" do
    before do
      create(:pvp_meta_talent_popularity,
        pvp_season: season, bracket: bracket, spec_id: spec_id, talent: talent,
        usage_pct: 80.0, in_top_build: true, tier: "bis", top_build_rank: 1, usage_count: 80)
    end

    it "returns high confidence when total_players >= 100 and stale_count == 0" do
      # Stub count_raw_players to return 100 without needing full leaderboard setup
      allow_any_instance_of(Pvp::Meta::TalentsResponseService)
        .to receive(:count_raw_players).and_return(100)

      get_talents
      json = JSON.parse(response.body)

      expect(json.dig("meta", "data_confidence")).to eq("high")
      expect(json.dig("meta", "stale_count")).to eq(0)
    end
  end

  context "with low confidence data" do
    before do
      # Stale-looking record: usage_pct < 1.0, not in_top_build, tier=common
      create(:pvp_meta_talent_popularity,
        pvp_season: season, bracket: bracket, spec_id: spec_id, talent: talent,
        usage_pct: 0.5, in_top_build: false, tier: "common", top_build_rank: 0, usage_count: 1)
    end

    it "returns low confidence when total_players < 30" do
      allow_any_instance_of(Pvp::Meta::TalentsResponseService)
        .to receive(:count_raw_players).and_return(5)

      get_talents
      json = JSON.parse(response.body)

      expect(json.dig("meta", "data_confidence")).to eq("low")
      expect(json.dig("meta", "stale_count")).to eq(1)
    end
  end

  describe "Pvp::Meta::ConfidenceScore" do
    it "returns high when total_players >= 100 and stale_count == 0" do
      expect(Pvp::Meta::ConfidenceScore.for(total_players: 100, stale_count: 0)).to eq("high")
    end

    it "returns medium when total_players >= 30 and stale_count <= 5" do
      expect(Pvp::Meta::ConfidenceScore.for(total_players: 30, stale_count: 5)).to eq("medium")
    end

    it "returns low when total_players < 30" do
      expect(Pvp::Meta::ConfidenceScore.for(total_players: 29, stale_count: 0)).to eq("low")
    end

    it "returns low when stale_count > 5 even with enough players" do
      expect(Pvp::Meta::ConfidenceScore.for(total_players: 50, stale_count: 6)).to eq("low")
    end

    it "returns low when total_players < 30 regardless of stale_count" do
      expect(Pvp::Meta::ConfidenceScore.for(total_players: 29, stale_count: 99)).to eq("low")
    end
  end
end
