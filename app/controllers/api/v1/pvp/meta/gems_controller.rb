class Api::V1::Pvp::Meta::GemsController < Api::V1::BaseController
  include MetaParams

  def index
    cache_key = meta_cache_key("gems", bracket_param, spec_id_param, slot_param, socket_type_param, locale_param)
    json = meta_cache_fetch(cache_key) { serialize_gems_response }
    render json: json
    set_cache_headers
  end

  private

    def socket_type_param = @socket_type_param ||= validate_slot(params[:socket_type])

    def serialize_gems_response
      season = meta_season_for(PvpMetaGemPopularity)
      gems   = filtered_gems(season)
      gems.map { |r| Pvp::Meta::GemSerializer.new(r, locale: locale_param).call }
    end

    def filtered_gems(season)
      scope = PvpMetaGemPopularity.for_meta(season:, bracket: bracket_param, spec_id: spec_id_param)
      scope = scope.where(slot: slot_param) if slot_param.present?
      scope = scope.where(socket_type: socket_type_param) if socket_type_param.present?
      scope
    end
end
