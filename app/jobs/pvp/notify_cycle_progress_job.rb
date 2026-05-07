module Pvp
  class NotifyCycleProgressJob < ApplicationJob
    queue_as :default

    def perform(cycle_id, milestone, completed_batches: nil, expected_batches: nil, elapsed_seconds: nil,
eta_seconds_snap: nil)
      cycle = PvpSyncCycle.find_by(id: cycle_id)
      return unless cycle

      completed = completed_batches || cycle.completed_character_batches
      expected  = expected_batches  || cycle.expected_character_batches
      elapsed   = Pvp::Formatters.elapsed(elapsed_seconds || (Time.current - cycle.created_at))
      eta_raw   = eta_seconds_snap || cycle.eta_seconds
      eta_str   = eta_raw ? " · ETA #{Pvp::Formatters.elapsed(eta_raw)}" : ""

      season_name = cycle.pvp_season&.display_name || "Season #{cycle.pvp_season_id}"
      TelegramNotifier.send(
        "⏳ <b>Cycle ##{cycle.id} — #{milestone}% complete</b>\n" \
        "#{season_name} · Regions: #{cycle.regions.join(', ')}\n" \
        "#{completed}/#{expected} batches · #{elapsed} elapsed#{eta_str}"
      )
    end
  end
end
