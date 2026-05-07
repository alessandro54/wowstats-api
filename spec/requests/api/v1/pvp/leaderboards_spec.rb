require "rails_helper"

RSpec.describe "Api::V1::Pvp::Leaderboards", type: :request do
  let!(:current_season) { create(:pvp_season, is_current: true) }

  describe "GET /api/v1/pvp/:season/:region/leaderboards/:bracket" do
    context "with a mixed bracket (3v3)" do
      let!(:leaderboard) {
        create(:pvp_leaderboard, pvp_season: current_season, bracket: "3v3", region: "us")
      }

      let!(:frost_entries) do
        Array.new(3) do |i|
          create(:pvp_leaderboard_entry,
            pvp_leaderboard: leaderboard,
            spec_id:         251,
            rank:            i + 1,
            rating:          3000 - (i * 100)
          )
        end
      end

      let!(:fire_entries) do
        Array.new(3) do |i|
          create(:pvp_leaderboard_entry,
            pvp_leaderboard: leaderboard,
            spec_id:         63,
            rank:            i + 4,
            rating:          2700 - (i * 100)
          )
        end
      end

      it "returns top entries filtered by spec_id" do
        get "/api/v1/pvp/#{current_season.blizzard_id}/us/leaderboards/3v3", params: {
          spec_id: 251
        }

        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)

        expect(json.length).to eq(3)
        expect(json.map { |e| e["spec_id"] }.uniq).to eq([ 251 ])
      end

      it "returns entries ordered by rank" do
        get "/api/v1/pvp/#{current_season.blizzard_id}/us/leaderboards/3v3", params: {
          spec_id: 251
        }

        json = JSON.parse(response.body)
        ranks = json.map { |e| e["rank"] }

        expect(ranks).to eq(ranks.sort)
      end

      it "returns bad request when spec_id is missing" do
        get "/api/v1/pvp/#{current_season.blizzard_id}/us/leaderboards/3v3"

        expect(response).to have_http_status(:bad_request)
      end
    end

    context "with a mixed bracket (2v2)" do
      let!(:leaderboard) { create(:pvp_leaderboard, pvp_season: current_season, bracket: "2v2", region: "us") }

      it "requires spec_id" do
        get "/api/v1/pvp/#{current_season.blizzard_id}/us/leaderboards/2v2"

        expect(response).to have_http_status(:bad_request)
      end
    end

    context "with a mixed bracket (rbg)" do
      let!(:leaderboard) { create(:pvp_leaderboard, pvp_season: current_season, bracket: "rbg", region: "us") }

      it "requires spec_id" do
        get "/api/v1/pvp/#{current_season.blizzard_id}/us/leaderboards/rbg"

        expect(response).to have_http_status(:bad_request)
      end
    end

    context "with a shuffle bracket" do
      let!(:leaderboard) {
          create(:pvp_leaderboard,
           pvp_season: current_season,
           bracket:    "shuffle-frost-deathknight",
           region:     "eu")
        }

      let!(:entries) do
        Array.new(5) do |i|
          create(:pvp_leaderboard_entry,
            pvp_leaderboard: leaderboard,
            spec_id:         251,
            rank:            i + 1,
            rating:          3000 - (i * 100)
          )
        end
      end

      it "returns top entries without requiring spec_id" do
        get "/api/v1/pvp/#{current_season.blizzard_id}/eu/leaderboards/shuffle-frost-deathknight"

        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)

        expect(json.length).to eq(5)
      end
    end

    context "with limit of 10" do
      let!(:leaderboard) {
          create(:pvp_leaderboard,
           pvp_season: current_season,
           bracket:    "shuffle-arms-warrior",
           region:     "us")
        }

      let!(:entries) do
        Array.new(15) do |i|
          create(:pvp_leaderboard_entry,
            pvp_leaderboard: leaderboard,
            rank:            i + 1,
            rating:          3000 - (i * 50)
          )
        end
      end

      it "returns at most 10 entries" do
        get "/api/v1/pvp/#{current_season.blizzard_id}/us/leaderboards/shuffle-arms-warrior"

        json = JSON.parse(response.body)

        expect(json.length).to eq(10)
      end
    end

    context "with invalid season" do
      it "returns not found" do
        get "/api/v1/pvp/9999/us/leaderboards/3v3", params: { spec_id: 62 }

        expect(response).to have_http_status(:not_found)
      end
    end

    context "with a 24h baseline snapshot" do
      let!(:leaderboard) {
        create(:pvp_leaderboard, pvp_season: current_season, bracket: "3v3", region: "us")
      }
      let!(:char) { create(:character) }

      before do
        create(:pvp_leaderboard_entry,
               character:       char,
               pvp_leaderboard: leaderboard,
               spec_id:         251,
               rank:            1, rating: 2800, wins: 50, losses: 20)
        create(:pvp_leaderboard_entry_snapshot,
               character: char, pvp_leaderboard: leaderboard,
               snapshot_at: 30.hours.ago,
               rank:        5, rating: 2700, wins: 40, losses: 18)
      end

      it "includes delta on the entry" do
        get "/api/v1/pvp/#{current_season.blizzard_id}/us/leaderboards/3v3", params: { spec_id: 251 }
        expect(response).to have_http_status(:ok)
        entry = JSON.parse(response.body).first
        expect(entry["delta"]).to eq(
          "rank" => -4,
          "rating" => 100,
          "wins" => 10,
          "losses" => 2
        )
      end
    end

    context "with no baseline snapshot" do
      let!(:leaderboard) {
        create(:pvp_leaderboard, pvp_season: current_season, bracket: "3v3", region: "us")
      }
      let!(:entry) {
        create(:pvp_leaderboard_entry, pvp_leaderboard: leaderboard, spec_id: 251, rank: 1, rating: 2800)
      }

      it "returns delta as null" do
        get "/api/v1/pvp/#{current_season.blizzard_id}/us/leaderboards/3v3", params: { spec_id: 251 }
        expect(JSON.parse(response.body).first["delta"]).to be_nil
      end
    end
  end
end
