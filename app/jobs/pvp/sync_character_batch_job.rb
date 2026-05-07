module Pvp
  class SyncCharacterBatchJob < ApplicationJob
    self.enqueue_after_transaction_commit = :always
    queue_as :character_sync_us # overridden per-region via .set(queue:) when enqueued

    retry_on Blizzard::Client::Error, wait: :exponentially_longer, attempts: 3 do |_job, error|
      Rails.logger.warn("[SyncCharacterBatchJob] API error, will retry: #{error.message}")
    end

    # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    def perform(character_ids:, locale: "en_US", sync_cycle_id: nil, region: nil)
      @sync_cycle_id = sync_cycle_id
      @region        = region

      ids = Array(character_ids).compact
      return if ids.empty?
      return if cycle_aborted?(sync_cycle_id)

      characters_by_id = Character
        .where(id: ids)
        .where(is_private: false)
        .where("unavailable_until IS NULL OR unavailable_until < ?", Time.current)
        .index_by(&:id)

      enqueue_meta_sync_for_stale(ids)

      return if characters_by_id.empty?

      outcome = BatchOutcome.new
      process_characters_concurrently(characters_by_id.values, locale, outcome)

      Rails.logger.info(
        outcome.summary_message(job_label: "SyncCharacterBatchJob", cycle_id: sync_cycle_id, region: region)
      )
      Pvp::SyncLogger.batch_complete(outcome: outcome)
      outcome.raise_if_total_failure!(job_label: "SyncCharacterBatchJob")
    ensure
      track_sync_cycle_completion
    end
    # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

    private

      def process_characters_concurrently(characters, locale, outcome)
        return if characters.empty?

        character_ids = characters.map(&:id)

        # Three bulk queries replace up to 3N per-character queries:
        #   1. Latest entry per bracket (for entries passed to service)
        #   2. Latest processed entry for equipment 304 fallback attrs
        #   3. Latest processed entry for spec 304 fallback attrs
        entries_by_character_id      = batch_load_entries(character_ids)
        eq_fallbacks_by_character_id = batch_load_eq_fallbacks(character_ids)
        sp_fallbacks_by_character_id = batch_load_spec_fallbacks(character_ids)

        # Both region workers (US + EU) run in the same OS process and share DB_POOL.
        # Divide by REGIONS.size so the total peak across all workers stays within the pool.
        total_threads = Pvp::SyncConfig::SYNC_THREADS * Pvp::SyncConfig::CHARACTER_SYNC_PROCESSES *
                        Pvp::RegionConfig::REGIONS.size
        concurrency   = safe_concurrency(Pvp::SyncConfig::SYNC_CONCURRENCY, characters.size, threads: total_threads)

        run_with_threads(characters, concurrency: concurrency) do |character|
          sync_one(
            character:            character,
            locale:               locale,
            outcome:              outcome,
            entries:              entries_by_character_id[character.id] || [],
            eq_fallback_source:   eq_fallbacks_by_character_id[character.id],
            spec_fallback_source: sp_fallbacks_by_character_id[character.id]
          )
        end
      end

      # Latest entry with equipment attrs set — used when Blizzard returns 304
      # (unchanged) so we can propagate existing attrs without re-processing.
      def batch_load_eq_fallbacks(character_ids)
        PvpLeaderboardEntry
          .where(character_id: character_ids)
          .where.not(equipment_processed_at: nil)
          .select("DISTINCT ON (character_id) pvp_leaderboard_entries.*")
          .order("character_id, equipment_processed_at DESC")
          .index_by(&:character_id)
      end

      # Same for specialization attrs.
      def batch_load_spec_fallbacks(character_ids)
        PvpLeaderboardEntry
          .where(character_id: character_ids)
          .where.not(specialization_processed_at: nil)
          .select("DISTINCT ON (character_id) pvp_leaderboard_entries.*")
          .order("character_id, specialization_processed_at DESC")
          .index_by(&:character_id)
      end

      # One entry per leaderboard per character — group by character_id to
      # support characters appearing on multiple brackets/regions.
      def batch_load_entries(character_ids)
        PvpLeaderboardEntry
          .where(character_id: character_ids)
          .group_by(&:character_id)
      end

      # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
      def sync_one(character:, locale:, outcome:, entries: nil, eq_fallback_source: nil, spec_fallback_source: nil)
        return unless character

        result = Pvp::Characters::SyncCharacterService.call(
          character:            character,
          locale:               locale,
          entries:              entries,
          eq_fallback_source:   eq_fallback_source,
          spec_fallback_source: spec_fallback_source
        )

        if result.success?
          outcome.record_success(id: character.id, status: result.context[:status])
        else
          outcome.record_failure(id: character.id, status: :failed, error: result.error.to_s)
        end
      rescue Blizzard::Client::RateLimitedError => e
        Rails.logger.warn(
          "[SyncCharacterBatchJob] Rate limited for character #{character&.id}: #{e.message}"
        )
        outcome.record_failure(id: character&.id, status: :rate_limited, error: e.message)
      rescue Blizzard::Client::Error => e
        Rails.logger.warn(
          "[SyncCharacterBatchJob] API error for character #{character&.id}: #{e.message}"
        )
        outcome.record_failure(id: character&.id, status: :api_error, error: e.message)
      rescue => e
        Rails.logger.error(
          "[SyncCharacterBatchJob] Unexpected error for character #{character&.id}: #{e.class}: #{e.message}"
        )
        outcome.record_failure(id: character&.id, status: :unexpected_error, error: "#{e.class}: #{e.message}")
      end
      # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

      def cycle_aborted?(sync_cycle_id)
        return false unless sync_cycle_id

        if PvpSyncCycle.where(id: sync_cycle_id, status: :aborted).exists?
          Rails.logger.info("[SyncCharacterBatchJob] Cycle ##{sync_cycle_id} aborted — skipping batch")
          return true
        end

        false
      end

      def enqueue_meta_sync_for_stale(character_ids)
        stale_ids = Character
          .where(id: character_ids)
          .where(is_private: false)
          .where("meta_synced_at IS NULL OR meta_synced_at < ?", Pvp::SyncConfig::META_TTL.ago)
          .pluck(:id)

        return if stale_ids.empty?

        ::Characters::SyncCharacterMetaBatchJob.perform_later(character_ids: stale_ids)
        Rails.logger.info("[SyncCharacterBatchJob] Enqueued meta batch for #{stale_ids.size} stale characters")
      end

      def track_sync_cycle_completion
        return unless @sync_cycle_id

        cycle = PvpSyncCycle.find_by(id: @sync_cycle_id)
        return unless cycle

        cycle.increment_completed_character_batches!

        if cycle.all_character_batches_done?
          elapsed = (Time.current - cycle.created_at).round
          season_name = cycle.pvp_season&.display_name || "Season #{cycle.pvp_season_id}"
          Pvp::SyncLogger.characters_complete(cycle: cycle, season_name: season_name, elapsed_seconds: elapsed)
          Pvp::RecoverFailedCharacterSyncsJob.perform_later(cycle.id)
        end
      rescue => e
        Rails.logger.error("[SyncCharacterBatchJob] Failed to track sync cycle #{@sync_cycle_id}: #{e.message}")
      end
  end
end
