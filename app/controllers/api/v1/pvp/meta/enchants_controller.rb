class Api::V1::Pvp::Meta::EnchantsController < Api::V1::BaseController
  include MetaParams

  def index
    cache_key = meta_cache_key("enchants", bracket_param, spec_id_param, slot_param, locale_param)
    json = meta_cache_fetch(cache_key) { serialize_enchants_response }
    render json: json
    set_cache_headers
  end

  private

    def serialize_enchants_response
      season   = meta_season_for(PvpMetaEnchantPopularity)
      enchants = filtered_enchants(season)
      serialized = enchants.map { |r| Pvp::Meta::EnchantSerializer.new(r, locale: locale_param).call }
      Pvp::Meta::EnchantVariantMerger.call(serialized)
    end

    def filtered_enchants(season)
      scope = PvpMetaEnchantPopularity.for_meta(season:, bracket: bracket_param, spec_id: spec_id_param)
      slot_param.present? ? scope.where(slot: slot_param) : scope
    end
end
