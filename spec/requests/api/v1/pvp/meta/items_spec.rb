require "rails_helper"

RSpec.describe "Api::V1::Pvp::Meta::Items", type: :request do
  let!(:current_season) { create(:pvp_season, is_current: true) }
  let!(:item) { create(:item, quality: "epic") }

  before do
    create(:translation,
      translatable: item,
      key:          "name",
      locale:       "en_US",
      value:        "Helm of Testing",
      meta:         { "source" => "test" }
    )
  end

  describe "GET /api/v1/pvp/meta/items" do
    context "with valid params" do
      let!(:item_popularity) do
        create(:pvp_meta_item_popularity,
          pvp_season:  current_season,
          item:        item,
          bracket:     "3v3",
          spec_id:     62,
          slot:        "head",
          usage_count: 50,
          usage_pct:   75.5
        )
      end

      it "returns items meta for the spec and bracket" do
        get "/api/v1/pvp/meta/items", params: { bracket: "3v3", spec_id: 62 }

        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)

        expect(json["items"]).to be_an(Array)
        expect(json["items"].first["item"]["name"]).to eq("Helm of Testing")
        expect(json["items"].first["slot"]).to eq("head")
        expect(json["items"].first["usage_pct"]).to eq(75.5)
        expect(json["meta"]).to have_key("snapshot_at")
      end

      it "filters by slot when provided" do
        create(:pvp_meta_item_popularity,
          pvp_season: current_season,
          bracket:    "3v3",
          spec_id:    62,
          slot:       "chest"
        )

        get "/api/v1/pvp/meta/items", params: { bracket: "3v3", spec_id: 62, slot: "head" }

        json = JSON.parse(response.body)
        expect(json["items"].length).to eq(1)
        expect(json["items"].first["slot"]).to eq("head")
      end
    end

    context "with missing params" do
      it "returns error when bracket is missing" do
        get "/api/v1/pvp/meta/items", params: { spec_id: 62 }

        expect(response).to have_http_status(:bad_request)
      end

      it "returns error when spec_id is missing" do
        get "/api/v1/pvp/meta/items", params: { bracket: "3v3" }

        expect(response).to have_http_status(:bad_request)
      end
    end
  end
end
