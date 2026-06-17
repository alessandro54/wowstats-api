class Api::V1::Pvp::Meta::InsightsController < Api::V1::Pvp::Meta::BaseController
  before_action :validate_meta_params!

  INSIGHT_CACHE_TTL = 4.hours

  # rubocop:disable Metrics/AbcSize
  def explain
    spec_name  = Wow::Specs.slug_for(spec_id_param)&.titleize || "Unknown Spec"
    cache_key  = meta_cache_key("insights", "explain", bracket_param, spec_id_param)

    payload = meta_cache_fetch(cache_key, expires_in: INSIGHT_CACHE_TTL) do
      query          = "Why is #{spec_name} strong in #{bracket_param} PvP? Recent buffs, nerfs, abilities."
      context_result = Rag::RetrieveContextService.call(query: query)
      unless context_result.success?
        return render json: { error: "Failed to retrieve context" }, status: :unprocessable_entity
      end

      generate_result = Rag::GenerateInsightService.call(
        spec_name:      spec_name,
        bracket:        bracket_param,
        context_chunks: context_result.payload
      )
      unless generate_result.success?
        return render json: { error: "Failed to generate insight" }, status: :unprocessable_entity
      end

      { spec_id: spec_id_param, bracket: bracket_param, insight: generate_result.payload }
    end

    render json: payload
    set_cache_headers(max_age: INSIGHT_CACHE_TTL, stale_while_revalidate: INSIGHT_CACHE_TTL)
  end
  # rubocop:enable Metrics/AbcSize
end
