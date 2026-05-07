class Api::V1::Pvp::Meta::StatPriorityController < Api::V1::Pvp::Meta::BaseController
  before_action :validate_meta_params!

  # GET /api/v1/pvp/meta/stat_priority
  # Returns secondary stat priority as median in-game percentages across
  # top players in the given bracket + spec.
  def show
    serve_meta("stat_priority", bracket_param, spec_id_param) do
      stats = Pvp::Meta::StatPriorityService.new(
        season: current_season, bracket: bracket_param, spec_id: spec_id_param
      ).call.payload
      { bracket: bracket_param, spec_id: spec_id_param, stats: stats }
    end
  end
end
