class Api::V1::BaseController < ApplicationController
  before_action :prefetch_meta_prereqs

  private

    META_CACHE_TTL = 30.minutes
    META_CACHE_VERSION_KEY = "pvp_meta/version"

    VALID_BRACKET_PATTERN = /\A[a-z0-9\-]{1,60}\z/
    VALID_REGIONS = (Pvp::RegionConfig::REGIONS + [ nil ]).freeze
    VALID_ROLES   = %w[dps healer tank].freeze
    VALID_SLOT_PATTERN = /\A[a-z_]{1,30}\z/
    VALID_SPEC_IDS = Wow::Catalog::SPECS.keys.to_set.freeze

    def validate_bracket!(value)
      unless value.match?(VALID_BRACKET_PATTERN)
        render json: { error: "invalid bracket" }, status: :bad_request
        return nil
      end
      value
    end

    def validate_spec_id!(value)
      id = value.to_i
      unless VALID_SPEC_IDS.include?(id)
        render json: { error: "invalid spec_id" }, status: :bad_request
        return nil
      end
      id
    end

    def validate_region(value)
      VALID_REGIONS.include?(value) ? value : nil
    end

    def validate_role(value)
      VALID_ROLES.include?(value) ? value : nil
    end

    def validate_slot(value)
      return nil if value.blank?

      value.match?(VALID_SLOT_PATTERN) ? value : nil
    end

    def prefetch_meta_prereqs
      return if Rails.env.development?

      values = Rails.cache.read_multi(META_CACHE_VERSION_KEY, "pvp_season/current")
      @meta_cache_version = values[META_CACHE_VERSION_KEY] || 0
      @current_season     = values["pvp_season/current"]
    end

    # Builds a versioned cache key so all meta caches can be busted at once
    # by incrementing the version.
    def meta_cache_key(*segments)
      version = @meta_cache_version ||= (Rails.cache.read(META_CACHE_VERSION_KEY) || 0)
      "pvp_meta/v#{version}/#{segments.compact.join("/")}"
    end

    # Wraps Rails.cache.fetch. Dev uses Solid Cache (config/cache.yml +
    # the dev `cache` database), so meta responses cache in dev too — bump
    # META_CACHE_VERSION_KEY or clear the cache DB to force regeneration.
    def meta_cache_fetch(cache_key, expires_in: META_CACHE_TTL, &block)
      Rails.cache.fetch(cache_key, expires_in: expires_in, &block)
    end

    # Sets Cache-Control for CDN/browser caching.
    # Skipped in development so browsers and Next.js never cache API responses.
    def set_cache_headers(max_age: 5.minutes, stale_while_revalidate: 1.hour)
      return if Rails.env.development?

      expires_in max_age, public: true, stale_while_revalidate: stale_while_revalidate
    end

    def current_season
      @current_season ||= PvpSeason.current
    end

    # Returns the current season if it has aggregation data, otherwise falls
    # back to the most recent season that does. This prevents empty responses
    # during the first sync cycle of a new season.
    def meta_season_for(model_class)
      @meta_seasons ||= {}
      @meta_seasons[model_class] ||= begin
        if model_class.exists?(pvp_season_id: current_season.id)
          current_season
        else
          PvpSeason.where.not(id: current_season.id)
                   .order(blizzard_id: :desc)
                   .detect { |s| model_class.exists?(pvp_season_id: s.id) } || current_season
        end
      end
    end

    def locale_param
      loc = params[:locale]
      Wow::Locales::SUPPORTED_LOCALES.include?(loc) ? loc : "en_US"
    end
end
