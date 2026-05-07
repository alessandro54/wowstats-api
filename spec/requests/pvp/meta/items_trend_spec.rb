require "rails_helper"

RSpec.describe "GET /api/v1/pvp/meta/items", type: :request do
  let(:season) { create(:pvp_season, is_current: true) }
  let(:item)   { create(:item) }

  def get_items(bracket: "3v3", spec_id: 256)
    get "/api/v1/pvp/meta/items", params: { bracket: bracket, spec_id: spec_id }
  end

  context "when usage went up by more than 1.0" do
    before do
      create(:pvp_meta_item_popularity,
        pvp_season: season, bracket: "3v3", spec_id: 256,
        slot: "HEAD", item: item, usage_pct: 55.0, prev_usage_pct: 40.0
      )
    end

    it "returns trend: up" do
      get_items
      expect(response.parsed_body["items"].first["trend"]).to eq("up")
    end
  end

  context "when usage went down by more than 1.0" do
    before do
      create(:pvp_meta_item_popularity,
        pvp_season: season, bracket: "3v3", spec_id: 256,
        slot: "HEAD", item: item, usage_pct: 30.0, prev_usage_pct: 45.0
      )
    end

    it "returns trend: down" do
      get_items
      expect(response.parsed_body["items"].first["trend"]).to eq("down")
    end
  end

  context "when prev_usage_pct is nil" do
    before do
      create(:pvp_meta_item_popularity,
        pvp_season: season, bracket: "3v3", spec_id: 256,
        slot: "HEAD", item: item, usage_pct: 20.0, prev_usage_pct: nil
      )
    end

    it "returns trend: new" do
      get_items
      expect(response.parsed_body["items"].first["trend"]).to eq("new")
    end
  end

  context "when delta is within 1.0" do
    before do
      create(:pvp_meta_item_popularity,
        pvp_season: season, bracket: "3v3", spec_id: 256,
        slot: "HEAD", item: item, usage_pct: 20.5, prev_usage_pct: 20.0
      )
    end

    it "returns trend: stable" do
      get_items
      expect(response.parsed_body["items"].first["trend"]).to eq("stable")
    end
  end
end
