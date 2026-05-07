module Pvp
  class BuildAggregationsJob < ApplicationJob
    queue_as :default

    def perform(pvp_season_id:, sync_cycle_id: nil, cycle_started_at: nil)
      vacuum_character_tables
      Pvp::BuildAggregationsService.call(
        pvp_season_id:    pvp_season_id,
        sync_cycle_id:    sync_cycle_id,
        cycle_started_at: cycle_started_at
      )
    end

    private

      def vacuum_character_tables
        conn = ApplicationRecord.connection
        return if conn.open_transactions > 0

        conn.execute("VACUUM ANALYZE character_talents")
        conn.execute("VACUUM ANALYZE character_items")
      end
  end
end
