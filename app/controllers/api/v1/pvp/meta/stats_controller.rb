class Api::V1::Pvp::Meta::StatsController < Api::V1::Pvp::Meta::BaseController
  before_action :validate_meta_params!

  def index
    serve_meta("stats", bracket_param, spec_id_param) do
      serialize_stats_response
    end
  end

  private

    def serialize_stats_response
      season = meta_season_for(PvpMetaItemPopularity)
      row    = Pvp::Meta::CharacterStatsService.new(
        season:  season,
        bracket: bracket_param,
        spec_id: spec_id_param
      ).call || {}
      serialize_stat_row(row)
    end

    def serialize_stat_row(row)
      {
        avg_ilvl: row["avg_ilvl"]&.to_i,
        stats:    {
          "VERSATILITY" => row["versatility"]&.to_i || 0,
          "MASTERY_RATING" => row["mastery"]&.to_i || 0,
          "HASTE_RATING" => row["haste"]&.to_i || 0,
          "CRIT_RATING" => row["crit"]&.to_i || 0
        }
      }
    end
end
