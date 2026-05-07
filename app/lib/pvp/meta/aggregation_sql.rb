module Pvp
  module Meta
    # Shared SQL building blocks for all four meta aggregation services.
    # The CTEs are identical across item/enchant/gem — only the SELECT and
    # GROUP BY differ. Each service calls `top_chars_cte` and appends its
    # own projection on top.
    module AggregationSql
      # Max simultaneous bracket queries per aggregation service.
      # With 4 parallel aggregation threads (BuildAggregationsService) each
      # spawning up to this many bracket threads, total concurrent DB
      # connections = 4 × BRACKET_CONCURRENCY. Keep well inside DB_POOL.
      BRACKET_CONCURRENCY = ENV.fetch("PVP_AGG_BRACKET_CONCURRENCY", 3).to_i

      # Returns distinct bracket names for the season's leaderboards.
      def season_brackets
        PvpLeaderboard.where(pvp_season_id: season.id).distinct.pluck(:bracket)
      end

      # Runs `block` once per bracket using a bounded thread pool, collecting
      # all returned rows into a single flat array.
      #
      # Each thread checks out its own DB connection via `with_connection` so
      # the main aggregation thread's connection is never shared.
      #
      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      def run_per_bracket(brackets, concurrency: BRACKET_CONCURRENCY, &block)
        return [] if brackets.empty?

        results = []
        errors  = []
        mutex   = Mutex.new
        work    = brackets.dup

        Array.new([ concurrency, brackets.size ].min) do
          Thread.new do
            loop do
              bracket = mutex.synchronize { work.shift }
              break unless bracket

              ApplicationRecord.connection_pool.with_connection do
                rows = block.call(bracket)
                mutex.synchronize { results.concat(rows.to_a) }
              end
            rescue => e
              mutex.synchronize { errors << e }
              break
            end
          end
        end.each(&:join)

        raise errors.first if errors.any?

        results
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      # Returns the top_chars CTE SQL.
      #
      # When `bracket` is supplied the query is scoped to that single bracket,
      # which allows PostgreSQL to use the partial indexes
      # idx_entries_top_chars_equipment / idx_entries_top_chars_specialization
      # and avoids a full-season nested-loop over character_talents.
      #
      # Without a bracket filter (legacy / testing) the CTE covers all brackets
      # for the season in one pass.
      # rubocop:disable Metrics/MethodLength
      def top_chars_cte(bracket: nil)
        if bracket
          distinct_on  = "e.character_id"
          order_by     = "e.character_id, e.rating DESC"
          bracket_cond = "AND l.bracket = :bracket"
        else
          distinct_on  = "l.bracket, e.character_id"
          order_by     = "l.bracket, e.character_id, e.rating DESC"
          bracket_cond = ""
        end

        <<~SQL
          latest_per_char AS (
            SELECT DISTINCT ON (#{distinct_on})
              e.character_id,
              l.bracket,
              e.spec_id,
              e.rating
            FROM pvp_leaderboard_entries e
            JOIN pvp_leaderboards l ON l.id = e.pvp_leaderboard_id
            WHERE l.pvp_season_id = :season_id
              #{bracket_cond}
              AND e.spec_id IS NOT NULL
              AND e.equipment_processed_at IS NOT NULL
            ORDER BY #{order_by}
          ),
          ranked AS (
            SELECT *,
              RANK() OVER (PARTITION BY bracket, spec_id ORDER BY rating DESC) AS rk
            FROM latest_per_char
          ),
          top_chars AS (
            SELECT * FROM ranked WHERE rk <= :top_n
          )
        SQL
      end
      # rubocop:enable Metrics/MethodLength
    end
  end
end
