module Pvp
  module Meta
    class CharacterStatsService < BaseService
      include AggregationSql

      TOP_N = Pvp::SyncConfig::META_TOP_N

      def initialize(season:, bracket:, spec_id:, top_n: TOP_N)
        @season   = season
        @bracket  = bracket
        @spec_id  = spec_id
        @top_n    = top_n
      end

      def call
        ApplicationRecord.connection.select_one(
          ApplicationRecord.sanitize_sql_array([
            character_stats_sql,
            { season_id: season.id, top_n: top_n, bracket: bracket, spec_id: spec_id }
          ])
        )
      end

      private

        attr_reader :season, :bracket, :spec_id, :top_n

        def character_stats_sql
          <<~SQL
            WITH #{top_chars_cte},
            char_totals AS (
              SELECT
                t.character_id,
                AVG(ci.item_level)                                          AS avg_ilvl,
                COALESCE(SUM((ci.stats->>'HASTE_RATING')::numeric), 0)     AS haste,
                COALESCE(SUM((ci.stats->>'CRIT_RATING')::numeric), 0)      AS crit,
                COALESCE(SUM((ci.stats->>'MASTERY_RATING')::numeric), 0)   AS mastery,
                COALESCE(SUM((ci.stats->>'VERSATILITY')::numeric), 0)      AS versatility
              FROM top_chars t
              JOIN character_items ci
                ON ci.character_id = t.character_id AND ci.spec_id = t.spec_id
              WHERE t.bracket = :bracket AND t.spec_id = :spec_id
              GROUP BY t.character_id
            )
            SELECT
              ROUND(AVG(avg_ilvl))::int    AS avg_ilvl,
              ROUND(AVG(haste))::int       AS haste,
              ROUND(AVG(crit))::int        AS crit,
              ROUND(AVG(mastery))::int     AS mastery,
              ROUND(AVG(versatility))::int AS versatility
            FROM char_totals
          SQL
        end
    end
  end
end
