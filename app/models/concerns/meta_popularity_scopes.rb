module MetaPopularityScopes
  extend ActiveSupport::Concern

  included do
    class_attribute :meta_includes, default: nil

    scope :for_meta, ->(season:, bracket:, spec_id:) {
      base = (meta_includes ? includes(meta_includes) : all)
        .where(pvp_season: season, bracket:, spec_id:)
        .order(usage_pct: :desc)

      live_cycle_id = season.live_pvp_sync_cycle_id
      next base.where(pvp_sync_cycle_id: nil) unless live_cycle_id

      cycle_data = base.where(pvp_sync_cycle_id: live_cycle_id)
      cycle_data.exists? ? cycle_data : base.where(pvp_sync_cycle_id: nil)
    }
  end
end
