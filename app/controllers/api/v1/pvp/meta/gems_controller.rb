class Api::V1::Pvp::Meta::GemsController < Api::V1::Pvp::Meta::BaseController
  before_action :validate_meta_params!

  def index
    serve_meta("gems", bracket_param, spec_id_param, slot_param, socket_type_param, locale_param) do
      serialize_gems_response
    end
    enqueue_unsynced_items
  end

  private

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

    def enqueue_unsynced_items
      gems = PvpMetaGemPopularity
        .includes(:item)
        .where(pvp_season: meta_season_for(PvpMetaGemPopularity), bracket: bracket_param, spec_id: spec_id_param)
      unsynced_ids = gems.map(&:item).reject(&:meta_synced?).map(&:id)
      Items::SyncItemMetaBatchJob.perform_later(item_ids: unsynced_ids) if unsynced_ids.any?
    end
end
