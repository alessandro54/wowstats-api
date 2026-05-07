class Api::V1::Pvp::Meta::EnchantsController < Api::V1::Pvp::Meta::BaseController
  before_action :validate_meta_params!

  def index
    serve_meta("enchants", bracket_param, spec_id_param, slot_param, locale_param) do
      serialize_enchants_response
    end
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
