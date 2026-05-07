class Api::V1::Pvp::LeaderboardsController < Api::V1::BaseController
  MIXED_BRACKETS = %w[2v2 3v3 rbg].freeze

  before_action :set_season, :set_leaderboard, only: [ :show ]

  def show
    entries = @leaderboard.get_top_n(10, spec_id: spec_id_param)
    deltas  = Pvp::Leaderboards::LeaderboardDeltasQuery.new(@leaderboard.id).call

    payload = entries.map do |entry|
      Pvp::LeaderboardEntrySerializer.new(entry, delta: deltas[entry.character_id]).call
    end

    render json: payload
  end

  private

    def set_season
      @season = PvpSeason.find_by!(blizzard_id: params[:season])
    end

    def set_leaderboard
      @leaderboard = PvpLeaderboard.find_by!(
        pvp_season: @season,
        region:     params[:region],
        bracket:    params[:bracket]
      )
    end

    def spec_id_param
      return unless MIXED_BRACKETS.include?(params[:bracket])

      params.require(:spec_id).to_i
    end
end
