module Api
  module V1
    module Characters
      class TrendsController < Api::V1::BaseController
        WINDOW = 7.days

        def show
          character = find_character
          return render_not_found if character.nil?

          render json: { character: character_payload(character), trends: build_trends(character) }
        end

        private

          def find_character
            Character.find_by(
              "LOWER(region) = ? AND LOWER(realm) = ? AND LOWER(name) = ?",
              params[:region].downcase, params[:realm].downcase, params[:name].downcase
            )
          end

          def render_not_found
            render json: { error: "Not found" }, status: :not_found
          end

          def character_payload(character)
            { name: character.name, realm: character.realm, region: character.region }
          end

          def build_trends(character)
            rows = PvpLeaderboardEntrySnapshot
              .joins(:pvp_leaderboard)
              .where(character_id: character.id)
              .where(pvp_leaderboards: { pvp_season_id: current_season.id })
              .where("snapshot_at >= ?", WINDOW.ago)
              .order("pvp_leaderboards.bracket ASC, pvp_leaderboard_entry_snapshots.snapshot_at ASC")
              .pluck("pvp_leaderboards.bracket",
                     "pvp_leaderboards.region",
                     :snapshot_at, :rank, :rating, :wins, :losses, :spec_id)

            rows.group_by { |bracket, *| bracket }.map do |bracket, group|
              {
                bracket:   bracket,
                region:    group.first[1],
                snapshots: group.map { |_b, _r, at, rank, rating, wins, losses, spec_id|
                  { at: at, rank: rank, rating: rating, wins: wins, losses: losses, spec_id: spec_id }
                }
              }
            end
          end
      end
    end
  end
end
