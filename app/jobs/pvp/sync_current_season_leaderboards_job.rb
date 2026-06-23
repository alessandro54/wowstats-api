module Pvp
  class SyncCurrentSeasonLeaderboardsJob < ApplicationJob
    queue_as :default

    # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
    def perform(locale: "en_US")
      if (active = PvpSyncCycle.active)
        TelegramNotifier.send(
          "⏭️ <b>Sync skipped</b> — Cycle ##{active.id} still running\n" \
          "Status: #{active.status} · #{active.progress_pct}% complete"
        )
        return
      end

      begin
        Blizzard::Data::PvpSeasons::SyncCurrentSeasonService.call
      rescue => e # rubocop:disable Style/RescueStandardError
        Rails.logger.warn("[SyncCurrentSeasonLeaderboardsJob] Season auto-detect failed: #{e.message}")
      end

      # Ensure talent tree classifications are up to date before character sync
      # starts. This prevents new or reclassified talents (e.g. gateway hero
      # talents added in a patch) from being inserted with wrong talent_type by
      # UpsertFromRawSpecializationService before SyncTreeService has seen them.
      # Runs inline (not perform_later) so the tree is correct before any
      # character batch jobs are enqueued. Uses force: false — only fills gaps
      # (node_id IS NULL or spell_id IS NULL). The daily forced sync at 3am
      # handles position drift from full tree reorganisations.
      begin
        Blizzard::Data::Talents::SyncTreeService.call(force: false)
      rescue => e # rubocop:disable Style/RescueStandardError
        Rails.logger.warn("[SyncCurrentSeasonLeaderboardsJob] Tree sync failed: #{e.message}")
      end

      season = PvpSeason.current
      return unless season

      snapshot_at = Time.current
      sync_cycle  = nil
      sync_cycle  = PvpSyncCycle.create!(
        pvp_season:  season,
        regions:     Pvp::RegionConfig::REGIONS,
        snapshot_at: snapshot_at,
        status:      :syncing_leaderboards
      )

      Pvp::SyncLogger.start_cycle(
        cycle:       sync_cycle,
        season_name: season.display_name,
        regions:     Pvp::RegionConfig::REGIONS
      )

      # Phase 1: Discover brackets for all regions concurrently (parallel HTTP).
      brackets_by_region = discover_all_brackets_concurrently(season, locale)

      # Phase 2: Sync all brackets across all regions concurrently (parallel HTTP).
      # A character that appears in 2v2 AND shuffle is the same record —
      # dedup within the region so it is only fetched from Blizzard once.
      character_ids_by_region = sync_all_leaderboards_concurrently(season, brackets_by_region, snapshot_at, sync_cycle)
      Pvp::RegionConfig::REGIONS.each { |r| character_ids_by_region[r]&.uniq! }

      # Phase 3: Filter recently synced, build batches, enqueue per-region.
      region_batch_map, total_batches = build_region_batch_map(character_ids_by_region)

      sync_cycle.update!(status: :syncing_characters, expected_character_batches: total_batches)

      if total_batches.zero?
        sync_cycle.update!(status: :completed)
        Pvp::SyncLogger.end_cycle(cycle_id: sync_cycle.id, elapsed_seconds: Time.current - snapshot_at)
        return
      end

      enqueue_character_batches(region_batch_map, sync_cycle, locale)
    rescue StandardError
      sync_cycle&.update!(status: :failed)
      raise
    end
    # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

    private

      # Discover brackets for all regions concurrently via parallel HTTP calls.
      # Uses threads (not Async fibers) because HTTPX runs its own blocking event
      # loop and does not yield to the Async scheduler — threads release the GIL
      # during network I/O so both region requests truly run in parallel.
      def discover_all_brackets_concurrently(season, locale)
        results = run_with_threads(Pvp::RegionConfig::REGIONS, concurrency: Pvp::RegionConfig::REGIONS.size) do |region|
          region_locale = Pvp::RegionConfig::REGION_LOCALES.fetch(region, locale)
          brackets      = discover_brackets(season, region, region_locale)
          { region: region, brackets: brackets, locale: region_locale }
        end

        results.each_with_object({}) { |r, h| h[r[:region]] = r }
      end

      # Sync every bracket across every region concurrently.
      # Returns Hash[region => [character_id, ...]] (not yet deduped).
      # Uses threads for the same reason as discover_all_brackets_concurrently.
      # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
      def sync_all_leaderboards_concurrently(season, brackets_by_region, snapshot_at, sync_cycle)
        tasks = Pvp::RegionConfig::REGIONS.flat_map do |region|
          default       = { brackets: [], locale: Pvp::RegionConfig::REGION_LOCALES[region] }
          info          = brackets_by_region.fetch(region, default)
          region_locale = info[:locale] || Pvp::RegionConfig::REGION_LOCALES[region]
          Array(info[:brackets]).map { |b| { region: region, bracket: b, locale: region_locale } }
        end

        character_ids_by_region = Hash.new { |h, k| h[k] = [] }
        return character_ids_by_region if tasks.empty?

        concurrency = [ tasks.size, Pvp::SyncConfig::LEADERBOARD_CONCURRENCY ].min
        results = run_with_threads(tasks, concurrency: concurrency) do |task|
          result = Pvp::Leaderboards::SyncLeaderboardService.call(
            season:        season,
            bracket:       task[:bracket],
            region:        task[:region],
            locale:        task[:locale],
            snapshot_at:   snapshot_at,
            sync_cycle_id: sync_cycle.id
          )
          { region: task[:region], ids: result.context[:character_ids] } if result.success?
        rescue StandardError => e
          Rails.logger.error(
            "[SyncCurrentSeasonLeaderboardsJob] #{task[:region]}/#{task[:bracket]} failed: #{e.message}"
          )
          Sentry.capture_exception(e, extra: { region: task[:region], bracket: task[:bracket] })
          nil
        end

        results.each { |r| character_ids_by_region[r[:region]].concat(r[:ids] || []) if r }

        character_ids_by_region
      end
      # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

      def discover_brackets(season, region, locale)
        response = Blizzard::Api::GameData::PvpSeason::LeaderboardsIndex.fetch(
          pvp_season_id: season.blizzard_id,
          region:        region,
          locale:        locale
        )
        leaderboards  = response.fetch("leaderboards", [])
        bracket_names = leaderboards.map { |lb| lb.dig("name") }.compact

        # Accept all known brackets; skip dead/redundant ones (rbg, overalls).
        bracket_names.reject { |name| Pvp::BracketConfig::SKIP_BRACKETS.include?(name) }.select do |name|
          Pvp::BracketConfig.for(name).present?
        end
      rescue Blizzard::Client::Error => e
        Rails.logger.error(
          "[SyncCurrentSeasonLeaderboardsJob] Failed to discover brackets for #{region}: #{e.message}"
        )
        []
      end

      # Filters out recently synced characters, logs per-region stats, and
      # returns [region_batch_map, total_batches].
      # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
      def build_region_batch_map(character_ids_by_region)
        batch_size       = Pvp::SyncConfig::SYNC_BATCH_SIZE
        region_batch_map = {}
        total_batches    = 0

        character_ids_by_region.each do |region, char_ids|
          next if char_ids.empty?

          recently_synced = PvpLeaderboardEntry
            .where(character_id: char_ids)
            .where("equipment_processed_at > ?", Pvp::SyncConfig::EQUIPMENT_TTL.ago)
            .distinct.pluck(:character_id).to_set

          to_sync = char_ids.reject { |id| recently_synced.include?(id) }

          Rails.logger.info(
            "[SyncCurrentSeasonLeaderboardsJob] #{region}: " \
            "#{char_ids.size} total, #{to_sync.size} need API fetch " \
            "(#{char_ids.size - to_sync.size} recently synced — entries will reuse cache)"
          )
          Pvp::SyncLogger.leaderboards_synced(
            region:  region,
            total:   char_ids.size,
            to_sync: to_sync.size,
            skipped: char_ids.size - to_sync.size
          )

          # Pass ALL character IDs to the batch job — not just `to_sync`.
          # Characters filtered out here still have new entries (created by
          # SyncLeaderboardService) that need equipment/spec data. The batch
          # job handles TTL/cooldown filtering + cached-data propagation.
          region_batch_map[region] = char_ids.each_slice(batch_size).to_a
          total_batches += region_batch_map[region].size
        end

        [ region_batch_map, total_batches ]
      end
      # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

      def enqueue_character_batches(region_batch_map, sync_cycle, locale)
        region_batch_map.each do |region, batches|
          queue         = Pvp::RegionConfig::REGION_QUEUES.fetch(region, :character_sync_us)
          region_locale = Pvp::RegionConfig::REGION_LOCALES.fetch(region, locale)

          batches.each do |batch|
            Pvp::SyncCharacterBatchJob
              .set(queue: queue)
              .perform_later(
                character_ids: batch,
                locale:        region_locale,
                sync_cycle_id: sync_cycle.id,
                region:        region
              )
          end
        end
      end
  end
end
