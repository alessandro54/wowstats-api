class Api::V1::Pvp::Meta::TopPlayersController < Api::V1::Pvp::Meta::BaseController
  DEFAULT_REGIONS = %w[us eu].freeze

  before_action :validate_meta_params!

  def index
    regions = region_params
    serve_meta("top_players", bracket_param, spec_id_param, regions.join("+")) do
      Pvp::Meta::TopPlayersService.new(
        season:  current_season,
        bracket: bracket_param,
        spec_id: spec_id_param,
        regions: regions
      ).call.payload
    end
  end

  private

    def region_params
      @region_params ||= if params[:region].present?
        Array(params[:region]).select { |r| validate_region(r) }
      else
        DEFAULT_REGIONS
      end
    end
end
