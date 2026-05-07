module Pvp
  class BuildAggregationsService < BaseService
    AGGREGATIONS = [
      [ :items,    Pvp::Meta::ItemAggregationService,    PvpMetaItemPopularity    ],
      [ :enchants, Pvp::Meta::EnchantAggregationService, PvpMetaEnchantPopularity ],
      [ :gems,     Pvp::Meta::GemAggregationService,     PvpMetaGemPopularity     ],
      [ :talents,  Pvp::Meta::TalentAggregationService,  PvpMetaTalentPopularity  ]
    ].freeze

    def initialize(pvp_season_id:, sync_cycle_id: nil, cycle_started_at: nil)
      @pvp_season_id   = pvp_season_id
      @sync_cycle_id   = sync_cycle_id
      @cycle_started_at = cycle_started_at
    end

    # rubocop:disable Metrics/AbcSize
    def call
      season = PvpSeason.find_by(id: pvp_season_id)
      unless season
        log_warn("Season #{pvp_season_id} not found, skipping")
        return success(nil)
      end

      cycle = sync_cycle_id ? PvpSyncCycle.find_by(id: sync_cycle_id) : nil

      if cycle&.aborted?
        log_info("Cycle ##{cycle.id} aborted — skipping aggregations")
        return success(nil)
      end

      results = run_aggregations(season, cycle)
      log_completion(results)
      cycle ? handle_cycle_results(season, cycle, results) : finalize_without_cycle(results)
      success(results)
    end
    # rubocop:enable Metrics/AbcSize

    private

      attr_reader :pvp_season_id, :sync_cycle_id, :cycle_started_at

      # rubocop:disable Metrics/AbcSize
      def run_aggregations(season, cycle)
        results   = []
        agg_start = Time.current

        # Run services sequentially to avoid exhausting the DB connection pool.
        # Each service already parallelises internally (bracket-level threads via
        # run_per_bracket), so running 4 services in parallel would multiply the
        # peak connection count by 4 and cause ConnectionTimeoutError.
        AGGREGATIONS.each do |(key, service_class, _)|
          results << run_single_aggregation(key, service_class, season, cycle)
        end

        log_aggregations_complete(cycle, agg_start)
        results.to_h
      end

      def run_single_aggregation(key, service_class, season, cycle)
        started     = Time.current
        result      = service_class.call(season: season, cycle: cycle)
        elapsed     = (Time.current - started).round
        cycle_label = cycle ? "cycle=#{cycle.id} " : ""

        if result.success?
          Pvp::Meta::TalentIntegrityCheckService.call(season: season, cycle: cycle) if key == :talents
          count = result.context[:count]
          Rails.logger.info("[#{cycle_label}aggregations] #{key}: #{count} records (#{format_elapsed(elapsed)})")
          [ key, count ]
        else
          log_error("#{service_class} failed for season #{season.id}: #{result.error}")
          Pvp::SyncLogger.error("#{service_class} failed for season #{season.id}: #{result.error}")
          [ key, :failed ]
        end
      end
      # rubocop:enable Metrics/AbcSize

      def finalize_without_cycle(results)
        Pvp::SyncLogger.aggregations_complete(**results.slice(:items, :enchants, :gems, :talents))
        return unless sync_cycle_id

        Pvp::SyncLogger.end_cycle(cycle_id: sync_cycle_id, elapsed_seconds: elapsed_seconds)
      end

      def handle_cycle_results(season, cycle, results)
        if results.values.all? { |v| v != :failed }
          promote_cycle(season, cycle, results)
        else
          rollback_draft(cycle)
          failed_keys = results.select { |_, v| v == :failed }.keys
          Sentry.capture_message(
            "Aggregation cycle failed — live data preserved",
            extra: { cycle_id: cycle.id, failures: failed_keys }
          )
          TelegramNotifier.send(
            "🚨 <b>Aggregation cycle failed</b>\n" \
            "Cycle ##{cycle.id} — live data preserved\nFailed: #{failed_keys.join(', ')}"
          )
        end
      end

      def promote_cycle(season, cycle, results)
        ApplicationRecord.transaction do
          old_cycle_id = season.live_pvp_sync_cycle_id
          season.update!(live_pvp_sync_cycle_id: cycle.id)
          cycle.update!(status: :completed, completed_at: Time.current)
          purge_old_cycle_data(old_cycle_id) if old_cycle_id
        end
        bump_meta_cache
        Pvp::NotifyFrontendRevalidateService.call
        Pvp::WarmMetaCacheJob.perform_later
        enqueue_unsynced_item_icons(season)
        log_sync_report(season, cycle, results)
        Pvp::PurgeStaleCharacterDataJob.perform_later
      end

      def rollback_draft(cycle)
        ApplicationRecord.transaction do
          popularity_models.each { |m| m.where(pvp_sync_cycle_id: cycle.id).delete_all }
          cycle.update!(status: :failed)
        end
      end

      def purge_old_cycle_data(old_cycle_id)
        popularity_models.each { |m| m.where(pvp_sync_cycle_id: old_cycle_id).delete_all }
      end

      def popularity_models
        [ PvpMetaItemPopularity, PvpMetaEnchantPopularity,
          PvpMetaGemPopularity,  PvpMetaTalentPopularity ]
      end

      def bump_meta_cache
        Rails.cache.increment(Api::V1::BaseController::META_CACHE_VERSION_KEY)
        log_info("Meta cache version bumped")
      end

      def log_completion(results)
        log_info(
          "Season #{pvp_season_id} done — " \
          "items: #{results[:items]}, enchants: #{results[:enchants]}, " \
          "gems: #{results[:gems]}, talents: #{results[:talents]}"
        )
      end

      def log_sync_report(season, cycle, results)
        total  = PvpLeaderboardEntry
                   .joins(:pvp_leaderboard)
                   .where(pvp_leaderboards: { pvp_season_id: season.id })
                   .count
        failed = PvpLeaderboardEntry
                   .joins(:pvp_leaderboard)
                   .where(pvp_leaderboards: { pvp_season_id: season.id })
                   .where("equipment_processed_at IS NULL OR specialization_processed_at IS NULL")
                   .count
        Pvp::SyncLogger.cycle_complete(
          cycle:              cycle,
          season_name:        season.display_name,
          synced:             total - failed,
          total:              total,
          failed:             failed,
          aggregation_counts: results,
          elapsed_seconds:    elapsed_seconds
        )
        Pvp::NotifyFailedCharactersJob.perform_later(cycle.id, total: total, failed: failed)
      end

      def enqueue_unsynced_item_icons(season)
        item_ids = PvpMetaItemPopularity.where(pvp_season: season).distinct.pluck(:item_id) +
                   PvpMetaGemPopularity.where(pvp_season: season).distinct.pluck(:item_id)
        unsynced = Item.where(id: item_ids.uniq).reject(&:meta_synced?).map(&:id)
        Items::SyncItemMetaBatchJob.perform_later(item_ids: unsynced) if unsynced.any?
      end

      def elapsed_seconds
        return nil unless cycle_started_at

        Time.current - Time.zone.parse(cycle_started_at)
      end

      def log_aggregations_complete(cycle, agg_start)
        elapsed     = (Time.current - agg_start).round
        cycle_label = cycle ? "cycle=#{cycle.id} " : ""
        Rails.logger.info("[#{cycle_label}aggregations] all done in #{format_elapsed(elapsed)}")
      end

      def format_elapsed(seconds)
        return "#{seconds}s" if seconds < 60

        "#{(seconds / 60).floor}m #{(seconds % 60)}s"
      end
  end
end
