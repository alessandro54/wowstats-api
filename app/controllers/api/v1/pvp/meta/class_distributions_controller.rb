module Api
  module V1
    module Pvp
      module Meta
        class ClassDistributionsController < BaseController
          before_action :validate_show_params!, only: :show

          def show
            season, bracket, region, role = parse_distribution_params
            serve_meta("class_distribution", season.blizzard_id, bracket, region, role) do
              build_distribution_response(season, bracket, region, role)
            end
          end

          private

            def parse_distribution_params
              season = fetch_season
              bracket = params.fetch(:bracket)
              region = params.fetch(:region, "all")
              region = validate_region(region == "all" ? nil : region)
              role = params.fetch(:role, "dps")
              role = role == "all" ? nil : validate_role(role)
              [ season, bracket, region, role ]
            end

            def fetch_season
              return PvpSeason.find_by!(blizzard_id: params[:season_id].to_i) if params[:season_id].present?

              current_season
            end

            def build_distribution_response(season, bracket, region, role)
              distribution = ::Pvp::Meta::BayesianClassDistributionService
                .new(role:, season:, bracket:, region:).call

              distribution = ::Pvp::Meta::RankChangeService.new(
                distribution: distribution,
                season:       season,
                bracket:      bracket,
                region:       region,
                role:         role
              ).call.payload

              {
                season_id:     season.blizzard_id,
                bracket:,
                region:        region || "all",
                total_entries: distribution.sum { |row| row[:count] },
                classes:       distribution
              }
            end

            def validate_show_params!
              validate_bracket!(params.fetch(:bracket)) or return
            end
        end
      end
    end
  end
end
