module Pvp
  module Meta
    class GemAggregationService < AggregationBase
      private

        def model_class
          PvpMetaGemPopularity
        end

        def snapshot_keys
          %i[bracket spec_id slot socket_type item_id]
        end

        def record_fields(row)
          {
            bracket:     row["bracket"],
            spec_id:     row["spec_id"],
            slot:        row["slot"],
            socket_type: row["socket_type"],
            item_id:     row["item_id"]
          }
        end

        def popularity_sql(bracket)
          <<~SQL
            WITH #{top_chars_cte(bracket: bracket)},
            slot_totals AS (
              SELECT t.bracket, t.spec_id, ci.slot, COUNT(DISTINCT t.character_id) AS total
              FROM top_chars t
              JOIN character_items ci ON ci.character_id = t.character_id AND ci.spec_id = t.spec_id
              WHERE jsonb_array_length(ci.sockets) > 0
              GROUP BY t.bracket, t.spec_id, ci.slot
            ),
            gem_per_char AS (
              SELECT DISTINCT
                t.bracket,
                t.spec_id,
                ci.slot,
                socket->>'type'              AS socket_type,
                (socket->>'item_id')::bigint AS item_id,
                t.character_id
              FROM top_chars t
              JOIN character_items ci ON ci.character_id = t.character_id AND ci.spec_id = t.spec_id
              JOIN jsonb_array_elements(ci.sockets) AS socket ON TRUE
              WHERE socket->>'item_id' IS NOT NULL
                AND socket->>'type'    IS NOT NULL
            )
            SELECT
              g.bracket,
              g.spec_id,
              g.slot,
              g.socket_type,
              g.item_id,
              COUNT(*)                                       AS usage_count,
              ROUND(COUNT(*) * 100.0 / st.total, 2)         AS usage_pct,
              NOW()                                          AS snapshot_at
            FROM gem_per_char g
            JOIN slot_totals st
              ON st.bracket = g.bracket AND st.spec_id = g.spec_id AND st.slot = g.slot
            GROUP BY
              g.bracket, g.spec_id, g.slot, g.socket_type, g.item_id, st.total
            ORDER BY g.bracket, g.spec_id, g.slot, g.socket_type, usage_count DESC
          SQL
        end
    end
  end
end
