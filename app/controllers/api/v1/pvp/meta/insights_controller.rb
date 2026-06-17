class Api::V1::Pvp::Meta::InsightsController < Api::V1::Pvp::Meta::BaseController
  before_action :validate_meta_params!

  CACHE_TTL = 4.hours

  # rubocop:disable Metrics/AbcSize
  def explain
    spec_name = Wow::Specs.slug_for(spec_id_param)&.titleize || "Unknown Spec"
    cache_key = "pvp/meta/insights/v1/explain/#{bracket_param}/#{spec_id_param}"

    json = Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) do
      query = "Why is #{spec_name} strong in #{bracket_param} PvP? Recent buffs, nerfs, abilities."

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

      { spec_id: spec_id_param, bracket: bracket_param, insight: generate_result.payload }.to_json
    end

    render json: json
    set_cache_headers(max_age: CACHE_TTL, stale_while_revalidate: CACHE_TTL)
  end
  # rubocop:enable Metrics/AbcSize
end
