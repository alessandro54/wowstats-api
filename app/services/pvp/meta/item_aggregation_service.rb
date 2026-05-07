module Pvp
  module Meta
    class ItemAggregationService < BaseAggregationService
      aggregates model: PvpMetaItemPopularity, key_columns: %i[bracket spec_id slot item_id]

      private

        def aggregation_sql
          <<~SQL
            WITH #{top_chars_cte},
            slot_totals AS (
              SELECT t.bracket, t.spec_id, ci.slot, COUNT(*) AS total
              FROM top_chars t
              JOIN character_items ci ON ci.character_id = t.character_id AND ci.spec_id = t.spec_id
              GROUP BY t.bracket, t.spec_id, ci.slot
            )
            SELECT
              t.bracket,
              t.spec_id,
              ci.slot,
              ci.item_id,
              COUNT(*)                                  AS usage_count,
              ROUND(COUNT(*) * 100.0 / st.total, 2)    AS usage_pct,
              NOW()                                     AS snapshot_at
            FROM top_chars t
            JOIN character_items ci ON ci.character_id = t.character_id AND ci.spec_id = t.spec_id
            JOIN slot_totals st
              ON st.bracket = t.bracket AND st.spec_id = t.spec_id AND st.slot = ci.slot
            GROUP BY t.bracket, t.spec_id, ci.slot, ci.item_id, st.total
            ORDER BY t.bracket, t.spec_id, ci.slot, usage_count DESC
          SQL
        end

        def row_attrs(row)
          { slot: row["slot"], item_id: row["item_id"] }
        end
    end
  end
end
