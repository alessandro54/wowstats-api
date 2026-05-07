module MetaPopularityScopes
  extend ActiveSupport::Concern

  class_methods do
    # Declares the association+nested includes pulled in by `for_meta`.
    # Example: `meta_includes_for(item: :translations)`
    def meta_includes_for(spec)
      @meta_includes = spec
    end

    def meta_includes
      @meta_includes
    end
  end

  included do
    scope :for_meta, ->(season:, bracket:, spec_id:) {
      live_cycle_id = season.live_pvp_sync_cycle_id
      base = (meta_includes ? includes(meta_includes) : all)
               .where(pvp_season: season, bracket:, spec_id:)
               .order(usage_pct: :desc)
      live_cycle_id ? base.where(pvp_sync_cycle_id: live_cycle_id) : base
    }
  end
end
