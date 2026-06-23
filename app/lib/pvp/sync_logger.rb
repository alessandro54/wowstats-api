module Pvp
  # Dedicated logger for the PvP sync pipeline.
  #
  # Writes structured, human-readable sync events to log/pvp_sync.log,
  # separate from the main Rails log (which is noisy with SQL queries).
  #
  # Usage pattern per sync run:
  #
  #   SyncLogger.start_cycle(...)           # SyncCurrentSeasonLeaderboardsJob
  #   SyncLogger.leaderboards_synced(...)   # per region, same job
  #   SyncLogger.batch_complete(...)        # SyncCharacterBatchJob, once per batch
  #   SyncLogger.aggregations_complete(...) # BuildAggregationsJob
  #   SyncLogger.end_cycle(...)             # BuildAggregationsJob, prints closing separator
  #
  module SyncLogger
    LOG_PATH  = Rails.root.join("log", "pvp_sync.log")
    SEPARATOR = ("═" * 80).freeze

    def self.logger
      @logger ||= if Rails.env.production?
        Rails.logger
      else
        logger = Logger.new(LOG_PATH, "daily", progname: "pvp_sync")
        logger.formatter = proc do |_severity, datetime, _progname, msg|
          "[#{datetime.strftime('%Y-%m-%d %H:%M:%S')}] #{msg}\n"
        end
        logger
      end
    end

    # ── Cycle start ──────────────────────────────────────────────────────────

    def self.start_cycle(cycle:, season_name:, regions:)
      logger.info(SEPARATOR)
      logger.info(
        "SYNC CYCLE ##{cycle.id} STARTED  |  Season: #{season_name}  |  Regions: #{regions.join(', ')}"
      )
      logger.info(SEPARATOR)
      cycle.notify_telegram(
        "🔄 <b>Sync started</b>\nCycle ##{cycle.id} — #{season_name}\nRegions: #{regions.join(', ')}"
      )
    end

    # ── Phase 1 — Leaderboard discovery ─────────────────────────────────────

    def self.leaderboards_synced(region:, total:, to_sync:, skipped:)
      logger.info(
        "  [leaderboards] #{region.upcase.ljust(3)}  " \
        "#{total} chars → #{to_sync} to sync  (#{skipped} recently synced)"
      )
    end

    # ── Phase 1b — Snapshot insertion ────────────────────────────────────────

    def self.snapshots_inserted(count:, leaderboard:)
      logger.info(
        "  [snapshot] #{leaderboard.region}/#{leaderboard.bracket}: snapshots inserted=#{count}"
      )
    end

    # ── Phase 2 — Character batch sync ───────────────────────────────────────

    # rubocop:disable Metrics/AbcSize
    def self.batch_complete(outcome:)
      succeeded = outcome.successes.size
      failed    = outcome.failures.size
      total     = outcome.total

      counts = outcome.counts_by_status
                      .map { |status, count| "#{status}: #{count}" }
                      .join(", ")

      line = "  [batch]  #{succeeded}/#{total} ok"
      line += ", #{failed} failed" if failed > 0
      line += "  { #{counts} }"

      if outcome.failures.any?
        samples = outcome.failures.first(3).map { |f| "char #{f[:id]}: #{f[:error]}" }.join(" | ")
        line += "  ⚠ #{samples}"
        line += " (+#{failed - 3} more)" if failed > 3
      end

      logger.info(line)
    end
    # rubocop:enable Metrics/AbcSize

    # ── Phase 2 complete — all character batches done ────────────────────────

    def self.characters_complete(cycle:, season_name:, elapsed_seconds: nil)
      elapsed = elapsed_seconds ? " in #{format_elapsed(elapsed_seconds)}" : ""
      logger.info("SYNC CYCLE ##{cycle.id} — characters complete#{elapsed}, running aggregations")
      cycle.notify_telegram(
        "✓ <b>Characters synced#{elapsed}</b>\n" \
        "Cycle ##{cycle.id} — #{season_name}\n" \
        "#{cycle.completed_character_batches}/#{cycle.expected_character_batches} batches · aggregating…"
      )
    end

    # ── Phase 3 — Aggregations ───────────────────────────────────────────────

    def self.aggregations_complete(items:, enchants:, gems:, talents: nil)
      logger.info(
        "  [aggregations]  items=#{items}  enchants=#{enchants}  gems=#{gems}  talents=#{talents}"
      )
    end

    # ── Cycle end ─────────────────────────────────────────────────────────────

    def self.end_cycle(cycle_id:, elapsed_seconds: nil)
      elapsed = elapsed_seconds ? "  (#{format_elapsed(elapsed_seconds)})" : ""
      logger.info("SYNC CYCLE ##{cycle_id} COMPLETE#{elapsed}")
      logger.info(SEPARATOR)
      logger.info("")
    end

    # ── Sync report — successful cycle completion ─────────────────────────────

    # rubocop:disable Metrics/AbcSize
    def self.cycle_complete(cycle:, season_name:, synced:, total:, failed:,
                            aggregation_counts:, elapsed_seconds: nil)
      elapsed = elapsed_seconds ? "  (#{format_elapsed(elapsed_seconds)})" : ""
      char_line = "#{synced}/#{total} synced"
      char_line += "  (#{failed} failed)" if failed > 0

      logger.info(SEPARATOR)
      logger.info("SYNC REPORT — Cycle ##{cycle.id} — Season: #{season_name}#{elapsed}")
      logger.info("  Regions     : #{cycle.regions.join(', ')}")
      logger.info("  Characters  : #{char_line}")
      logger.info(
        "  Aggregations: items=#{aggregation_counts[:items]}" \
        "  enchants=#{aggregation_counts[:enchants]}" \
        "  gems=#{aggregation_counts[:gems]}" \
        "  talents=#{aggregation_counts[:talents]}"
      )
      logger.info("  Snapshot    : #{cycle.snapshot_at&.strftime('%Y-%m-%d %H:%M:%S %Z')}")
      logger.info(SEPARATOR)
      logger.info("")
      cycle.notify_telegram(telegram_cycle_complete_message(cycle, season_name, char_line, aggregation_counts, elapsed))
    end
    # rubocop:enable Metrics/AbcSize

    # ── Errors ────────────────────────────────────────────────────────────────

    def self.error(message)
      logger.error("  [error]  #{message}")
      TelegramNotifier.send("🚨 <b>Sync error</b>\n<code>#{message}</code>")
    end

    private_class_method def self.format_elapsed(seconds) = Pvp::Formatters.elapsed_short(seconds)

    private_class_method def self.telegram_cycle_complete_message(cycle, season_name, char_line, counts, elapsed)
      agg = "items=#{counts[:items]}  enchants=#{counts[:enchants]}  gems=#{counts[:gems]}  talents=#{counts[:talents]}"
      <<~MSG.strip
        ✅ <b>Sync complete</b>#{elapsed}
        Cycle ##{cycle.id} — #{season_name}
        Regions: #{cycle.regions.join(', ')}
        Characters: #{char_line}
        <code>#{agg}</code>
      MSG
    end
  end
end
