module Pvp
  module Meta
    # Median secondary-stat percentages across players in a (bracket, spec_id)
    # leaderboard. Uses PERCENTILE_CONT directly on character.stat_pcts JSONB.
    class StatPriorityService < BaseService
      def initialize(season:, bracket:, spec_id:)
        @season  = season
        @bracket = bracket
        @spec_id = spec_id
      end

      def call
        rows = stat_medians_sql
        success(rows.map { |stat, median| { stat: stat, median: median.to_f.round(1) } })
      end

      private

        attr_reader :season, :bracket, :spec_id

        def stat_medians_sql
          conn = ApplicationRecord.connection
          conn.select_rows(<<~SQL.squish)
            SELECT
              kv.key AS stat,
              PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY kv.value::numeric) AS median
            FROM characters
            INNER JOIN pvp_leaderboard_entries ON pvp_leaderboard_entries.character_id = characters.id
            INNER JOIN pvp_leaderboards ON pvp_leaderboards.id = pvp_leaderboard_entries.pvp_leaderboard_id
            CROSS JOIN LATERAL jsonb_each_text(characters.stat_pcts) AS kv(key, value)
            WHERE pvp_leaderboards.bracket = #{conn.quote(bracket)}
              AND pvp_leaderboards.pvp_season_id = #{season.id.to_i}
              AND pvp_leaderboard_entries.spec_id = #{spec_id.to_i}
              AND characters.stat_pcts <> '{}'
            GROUP BY kv.key
            ORDER BY median DESC
          SQL
        end
    end
  end
end
