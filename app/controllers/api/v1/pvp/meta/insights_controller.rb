class Api::V1::Pvp::Meta::InsightsController < Api::V1::Pvp::Meta::BaseController
  before_action :validate_meta_params!
  before_action :restrict_to_arena_brackets!

  INSIGHT_CACHE_TTL = 4.hours

  # Insights are only generated for arena brackets for now. Shuffle/blitz
  # per-spec brackets are excluded until their data is validated.
  INSIGHT_BRACKETS = %w[2v2 3v3].freeze

  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def explain
    spec_name = Wow::Specs.slug_for(spec_id_param)&.titleize || "Unknown Spec"
    cache_key = meta_cache_key("insights", "explain", bracket_param, spec_id_param)

    # `return render ...` below short-circuits the whole action (non-local
    # return from the block) so failures never get written to the cache.
    payload = meta_cache_fetch(cache_key, expires_in: INSIGHT_CACHE_TTL) do
      query          = "Why is #{spec_name} strong in #{bracket_param} PvP? Recent buffs, nerfs, abilities."
      context_result = Rag::RetrieveContextService.call(
        query:   query,
        spec_id: spec_id_param,
        bracket: bracket_param,
        season:  meta_season_for(PvpMetaTalentPopularity)
      )
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
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

  private

    def restrict_to_arena_brackets!
      return if INSIGHT_BRACKETS.include?(bracket_param)

      render json: {
        error:     "Insights are only available for 2v2 and 3v3.",
        bracket:   bracket_param,
        supported: INSIGHT_BRACKETS
      }, status: :unprocessable_entity
    end
end
