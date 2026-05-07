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
        Rails.logger.warn("[BuildAggregationsService] Season #{pvp_season_id} not found, skipping")
        return success(nil)
      end

      cycle = sync_cycle_id ? PvpSyncCycle.find_by(id: sync_cycle_id) : nil

      if cycle&.aborted?
        Rails.logger.info("[BuildAggregationsService] Cycle ##{cycle.id} aborted — skipping aggregations")
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

      def run_aggregations(season, cycle)
        results = []
        mutex   = Mutex.new
        work    = AGGREGATIONS.dup

        Array.new(AGGREGATIONS.size) do
          Thread.new do
            loop do
              tuple = mutex.synchronize { work.shift }
              break unless tuple

              key, service_class, = tuple
              result = run_single_aggregation(key, service_class, season, cycle)
              mutex.synchronize { results << result }
            end
          end
        end.each(&:join)

        results.to_h
      end

      def run_single_aggregation(key, service_class, season, cycle)
        result = service_class.call(season: season, cycle: cycle)
        if result.success?
          [ key, result.context[:count] ]
        else
          Rails.logger.error(
            "[BuildAggregationsService] #{service_class} failed for season #{season.id}: #{result.error}"
          )
          Pvp::SyncLogger.error("#{service_class} failed for season #{season.id}: #{result.error}")
          [ key, :failed ]
        end
      end

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
        Rails.logger.info("[BuildAggregationsService] Meta cache version bumped")
      end

      def log_completion(results)
        Rails.logger.info(
          "[BuildAggregationsService] Season #{pvp_season_id} done — " \
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

      def elapsed_seconds
        return nil unless cycle_started_at

        Time.current - Time.zone.parse(cycle_started_at)
      end
  end
end
