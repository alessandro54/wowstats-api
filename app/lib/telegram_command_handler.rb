# Handles inbound Telegram bot commands from whitelisted chat IDs.
class TelegramCommandHandler
  COMMANDS = {
    "/help" => :cmd_help,
    "/cycle" => :cmd_cycle,
    "/status" => :cmd_cycle,
    "/history" => :cmd_history,
    "/errors" => :cmd_errors,
    "/jobs" => :cmd_jobs,
    "/syncnow" => :cmd_sync_now,
    "/abort" => :cmd_abort,
    "/revalidate_cache" => :cmd_revalidate_cache
  }.freeze

  def initialize(chat_id, text)
    @chat_id = chat_id.to_s
    @text    = text.to_s.strip
  end

  def call
    unless TelegramNotifier.allowed?(@chat_id)
      Rails.logger.warn("[TelegramBot] Unauthorized chat_id=#{@chat_id}")
      return
    end

    command = @text.split.first&.downcase
    handler = COMMANDS[command]

    if handler
      send(handler)
    else
      TelegramNotifier.reply(@chat_id, "Unknown command. Try /help")
    end
  end

  private

    def cmd_help
      TelegramNotifier.reply(@chat_id, <<~MSG.strip)
      <b>WoW Overseer Bot</b>

      /cycle [id]   — cycle status (progress bar if active)
      /status       — alias for /cycle
      /history      — last 5 completed cycles
      /errors       — job errors in last 24h
      /jobs         — job success rate last 24h
      /syncnow           — trigger a sync immediately
      /abort &lt;id&gt;       — abort a running cycle
      /revalidate-cache  — force Next.js cache revalidation
    MSG
    end

    def cmd_cycle
      cycle_id = @text.split[1]&.to_i
      cycle    = if cycle_id&.positive?
        found = PvpSyncCycle.find_by(id: cycle_id)
        return TelegramNotifier.reply(@chat_id, "Cycle ##{cycle_id} not found.") unless found

        found
      else
        PvpSyncCycle.order(created_at: :desc).first
      end

      return TelegramNotifier.reply(@chat_id, "No sync cycles found.") unless cycle

      buttons = cycle_buttons(cycle)
      if buttons.any?
        TelegramNotifier.reply_with_buttons(@chat_id, cycle_message(cycle), buttons)
      else
        TelegramNotifier.reply(@chat_id, cycle_message(cycle))
      end
    end

    # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
    def cycle_message(cycle)
      season  = cycle.pvp_season
      active  = cycle.syncing_leaderboards? || cycle.syncing_characters?
      elapsed = Time.current - cycle.created_at

      lines = []
      lines << "<b>Cycle ##{cycle.id}</b> — #{season&.display_name || "Season #{season&.id}"}"
      lines << "Status: <b>#{cycle.status}</b>"
      lines << "Regions: #{cycle.regions.join(', ')}"

      if active
        pct     = cycle.progress_pct
        eta_str = cycle.eta_seconds ? " · ETA #{format_elapsed(cycle.eta_seconds)}" : ""
        lines << "Progress: #{progress_bar(pct)} #{pct}%"
        batches_line = "#{cycle.completed_character_batches}/#{cycle.expected_character_batches} batches"
        lines << "#{batches_line} · #{format_elapsed(elapsed)} elapsed#{eta_str}"
      elsif cycle.expected_character_batches > 0
        duration = cycle.completed_at ? format_elapsed(cycle.completed_at - cycle.created_at) : format_elapsed(elapsed)
        lines << "Batches: #{cycle.completed_character_batches}/#{cycle.expected_character_batches}"
        lines << "Duration: #{duration}"
        failed = count_failed_characters(cycle)
        lines << (failed > 0 ? "⚠️ Errors: #{failed} chars failed" : "✅ No errors")
      end

      lines << "Started: #{format_elapsed(elapsed)} ago"
      lines.join("\n")
    end
    # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

    def cmd_history
      cycles = PvpSyncCycle.where(status: :completed)
                           .where.not(completed_at: nil)
                           .order(created_at: :desc)
                           .limit(5)

      if cycles.empty?
        TelegramNotifier.reply(@chat_id, "No completed cycles found.")
        return
      end

      lines = cycles.map do |c|
        duration = format_elapsed(c.completed_at - c.created_at)
        "Cycle ##{c.id} · #{duration} · #{c.regions.join('/')}"
      end

      TelegramNotifier.reply(@chat_id, "<b>Last #{cycles.size} completed cycles</b>\n#{lines.join("\n")}")
    end

    def cmd_sync_now
      if (active = PvpSyncCycle.active)
        TelegramNotifier.reply(
          @chat_id,
          "⏭️ Sync already running — Cycle ##{active.id} (#{active.status}, #{active.progress_pct}%)"
        )
        return
      end

      Pvp::SyncCurrentSeasonLeaderboardsJob.perform_later
      TelegramNotifier.reply(@chat_id, "▶️ Sync triggered.")
    end

    def cmd_revalidate_cache
      result = Pvp::NotifyFrontendRevalidateService.call
      if result.success?
        TelegramNotifier.reply(@chat_id, "✅ Frontend cache revalidated.")
      else
        TelegramNotifier.reply(@chat_id, "❌ Revalidation failed — check logs.")
      end
    end

    def cmd_abort
      cycle_id = @text.split[1]&.to_i
      return TelegramNotifier.reply(@chat_id, "Usage: /abort <cycle_id>") unless cycle_id&.positive?

      cycle = PvpSyncCycle.find_by(id: cycle_id)
      return TelegramNotifier.reply(@chat_id, "Cycle ##{cycle_id} not found.") unless cycle

      unless cycle.syncing_leaderboards? || cycle.syncing_characters?
        return TelegramNotifier.reply(@chat_id, "Cycle ##{cycle_id} is #{cycle.status} — cannot abort.")
      end

      cycle.update!(status: :aborted)
      TelegramNotifier.reply(@chat_id, "🛑 Cycle ##{cycle_id} aborted.")
    end

    def cmd_errors
      dist = JobPerformanceMetric.error_distribution(24.hours)

      if dist.empty?
        TelegramNotifier.reply(@chat_id, "No job errors in the last 24h.")
        return
      end

      lines = dist.sort_by { |_, count| -count }
                  .map { |klass, count| "• #{klass || "unknown"}: #{count}" }
                  .join("\n")

      TelegramNotifier.reply(@chat_id, "<b>Job errors (24h)</b>\n#{lines}")
    end

    def cmd_jobs
      summary = JobPerformanceMetric.performance_summary(time_range: 24.hours)

      TelegramNotifier.reply(@chat_id, <<~MSG.strip)
      <b>Job summary (24h)</b>
      Total: #{summary[:total_jobs]}
      Success: #{summary[:successful_jobs]} (#{summary[:success_rate]}%)
      Failed: #{summary[:failed_jobs]}
      Avg duration: #{summary[:avg_duration]}s
    MSG
    end

    def count_failed_characters(cycle)
      PvpLeaderboardEntry
        .joins(:pvp_leaderboard)
        .where(pvp_leaderboards: { pvp_season_id: cycle.pvp_season_id })
        .where("equipment_processed_at IS NULL OR specialization_processed_at IS NULL")
        .count
    end

    def cycle_buttons(cycle)
      if cycle.syncing_leaderboards? || cycle.syncing_characters?
        [ [ { text: "🛑 Abort", callback_data: "abort:#{cycle.id}" } ] ]
      elsif cycle.failed? || cycle.aborted?
        [ [ { text: "🔄 Retry failed chars", callback_data: "retry:#{cycle.id}" } ] ]
      else
        []
      end
    end

    def progress_bar(pct, width: 10)
      filled = ((pct / 100.0) * width).round
      "█" * filled + "░" * (width - filled)
    end

    def format_elapsed(seconds) = Pvp::Formatters.elapsed(seconds)
end
