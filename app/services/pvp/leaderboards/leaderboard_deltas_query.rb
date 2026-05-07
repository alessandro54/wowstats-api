# frozen_string_literal: true

module Pvp
  module Leaderboards
    # Returns Hash[character_id => { rank:, rating:, wins:, losses: }]
    # for the most-recent snapshot in the 24-48h window prior to `now`.
    # Returns an empty Hash when no qualifying snapshots exist.
    class LeaderboardDeltasQuery
      def initialize(leaderboard_id, now: Time.current)
        @leaderboard_id = leaderboard_id
        @now            = now
      end

      def call
        fetch_rows.each_with_object({}) { |r, h| h[r["character_id"].to_i] = row_to_hash(r) }
      end

      private

        attr_reader :leaderboard_id, :now

        def fetch_rows
          ApplicationRecord.connection.select_all(
            ApplicationRecord.sanitize_sql_array([
              sql,
              { leaderboard_id: leaderboard_id, lower: now - 48.hours, upper: now - 24.hours }
            ])
          )
        end

        def row_to_hash(r)
          {
            rank:   r["rank"].to_i,
            rating: r["rating"].to_i,
            wins:   r["wins"].to_i,
            losses: r["losses"].to_i
          }
        end

        def sql
          <<~SQL
            SELECT DISTINCT ON (character_id)
              character_id, rank, rating, wins, losses, snapshot_at
            FROM pvp_leaderboard_entry_snapshots
            WHERE pvp_leaderboard_id = :leaderboard_id
              AND snapshot_at <= :upper
              AND snapshot_at >= :lower
            ORDER BY character_id, snapshot_at DESC
          SQL
        end
    end
  end
end
