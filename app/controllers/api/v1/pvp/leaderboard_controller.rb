class Api::V1::Pvp::LeaderboardController < Api::V1::BaseController
  DEFAULT_REGIONS = %w[us eu].freeze

  before_action :validate_params!

  def show
    serve
  end

  private

    def serve
      json = meta_cache_fetch(serve_cache_key) { build_payload }
      render json: json
      set_cache_headers
    end

    def serve_cache_key
      meta_cache_key(
        "leaderboard", bracket_param, region_params.join("+"),
        params[:class_slug] || "all", params[:spec_id] || "all",
        page_param, per_page_param, query_param,
        params[:min_rating] || "_", params[:max_rating] || "_",
        params[:min_winrate] || "_"
      )
    end

    def build_payload
      Pvp::LeaderboardService.new(**service_args).call.payload
    end

    def service_args
      {
        season:   current_season,
        bracket:  bracket_param,
        regions:  region_params,
        page:     page_param,
        per_page: per_page_param,
        query:    query_param
      }.merge(filter_args)
    end

    def filter_args
      {
        spec_id:     params[:spec_id].presence&.to_i,
        class_slug:  params[:class_slug].presence&.tr("-", "_"),
        min_rating:  params[:min_rating].presence,
        max_rating:  params[:max_rating].presence,
        min_winrate: params[:min_winrate].presence
      }
    end

    def validate_params!
      validate_bracket!(params.require(:bracket)) or return
    end

    def bracket_param
      @bracket_param ||= params.require(:bracket)
    end

    def region_params
      @region_params ||= if params[:region].present?
        Array(params[:region]).select { |r| validate_region(r) }
      else
        DEFAULT_REGIONS
      end
    end

    def page_param
      @page_param ||= [ params[:page].to_i, 1 ].max
    end

    def per_page_param
      @per_page_param ||= [ [ (params[:per_page].presence || 50).to_i, 1 ].max, 500 ].min
    end

    def query_param
      @query_param ||= params[:q].to_s.strip.presence
    end
end
