class Api::V1::Pvp::Meta::SpecsController < Api::V1::Pvp::Meta::BaseController
  def index
    serve_meta("specs", bracket_param) do
      Pvp::Meta::SpecStatsService.new(bracket: bracket_param).index.payload
    end
  end

  def show
    serve_meta("specs", bracket_param, spec_id_param, limit_param) do
      Pvp::Meta::SpecStatsService.new(
        bracket: bracket_param, spec_id: spec_id_param, limit: limit_param
      ).show.payload
    end
  end

  private

    def bracket_param
      params.require(:bracket)
    end

    def spec_id_param
      params[:id].to_i
    end

    def limit_param
      [ params[:limit]&.to_i || 20, 100 ].min
    end
end
