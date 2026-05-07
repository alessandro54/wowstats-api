class Api::V1::Pvp::Meta::ItemsController < Api::V1::Pvp::Meta::BaseController
  before_action :validate_meta_params!

  def index
    serve_meta("items", bracket_param, spec_id_param, slot_param, locale_param) do
      serialize_items_response
    end
    enqueue_unsynced_items
  end

  private

    def serialize_items_response
      season       = meta_season_for(PvpMetaItemPopularity)
      items        = filtered_items(season)
      crafting_map = Pvp::Meta::CraftingStatsQuery.new(
        items.map(&:item_id), season:, bracket: bracket_param, spec_id: spec_id_param
      ).call
      serialized = items.map { |r|
        Pvp::Meta::ItemSerializer.new(r, locale: locale_param, crafting_stats: crafting_map[r.item_id]).call
      }
      {
        meta:  { snapshot_at: items.first&.snapshot_at },
        items: serialized
      }
    end

    def filtered_items(season)
      scope = PvpMetaItemPopularity.for_meta(season:, bracket: bracket_param, spec_id: spec_id_param)
      slot_param.present? ? scope.where(slot: slot_param) : scope
    end

    def enqueue_unsynced_items
      items = PvpMetaItemPopularity
        .includes(:item)
        .where(pvp_season: meta_season_for(PvpMetaItemPopularity), bracket: bracket_param, spec_id: spec_id_param)
      unsynced_ids = items.map(&:item).reject(&:meta_synced?).map(&:id)
      Items::SyncItemMetaBatchJob.perform_later(item_ids: unsynced_ids) if unsynced_ids.any?
    end
end
