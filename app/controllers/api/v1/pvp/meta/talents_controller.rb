class Api::V1::Pvp::Meta::TalentsController < Api::V1::Pvp::Meta::BaseController
  before_action :validate_meta_params!, only: :index

  def index
    serve_meta("talents", bracket_param, spec_id_param, locale_param) do
      Pvp::Meta::TalentsResponseService.new(
        season:  meta_season_for(PvpMetaTalentPopularity),
        bracket: bracket_param,
        spec_id: spec_id_param,
        locale:  locale_param
      ).call.payload
    end
  end

  def show
    talent = Talent.includes(:translations).find_by(id: params[:id])
    return render json: { error: "not found" }, status: :not_found unless talent

    cache_key = "talents/tooltip/v1/#{params[:id]}/#{locale_param}"
    json = Rails.cache.fetch(cache_key, expires_in: 24.hours) do
      { id: talent.id, description: talent.t("description", locale: locale_param) }
    end
    render json: json
    set_cache_headers(max_age: 24.hours, stale_while_revalidate: 48.hours)
  end
end
