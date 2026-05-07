module Pvp
  module Meta
    class EnchantAggregationService < AggregationBase
      private

        def model_class
          PvpMetaEnchantPopularity
        end

        def snapshot_keys
          %i[bracket spec_id slot enchantment_id]
        end

        def record_fields(row)
          {
            bracket:        row["bracket"],
            spec_id:        row["spec_id"],
            slot:           row["slot"],
            enchantment_id: row["enchantment_id"]
          }
        end

        def popularity_sql(bracket)
          <<~SQL
            WITH #{top_chars_cte(bracket: bracket)},
            slot_totals AS (
              SELECT t.bracket, t.spec_id, ci.slot, COUNT(*) AS total
              FROM top_chars t
              JOIN character_items ci ON ci.character_id = t.character_id AND ci.spec_id = t.spec_id
              WHERE ci.enchantment_id IS NOT NULL
              GROUP BY t.bracket, t.spec_id, ci.slot
            )
            SELECT
              t.bracket,
              t.spec_id,
              ci.slot,
              ci.enchantment_id,
              COUNT(*)                                  AS usage_count,
              ROUND(COUNT(*) * 100.0 / st.total, 2)    AS usage_pct,
              NOW()                                     AS snapshot_at
            FROM top_chars t
            JOIN character_items ci
              ON ci.character_id = t.character_id AND ci.spec_id = t.spec_id AND ci.enchantment_id IS NOT NULL
            JOIN slot_totals st
              ON st.bracket = t.bracket AND st.spec_id = t.spec_id AND st.slot = ci.slot
            GROUP BY t.bracket, t.spec_id, ci.slot, ci.enchantment_id, st.total
            ORDER BY t.bracket, t.spec_id, ci.slot, usage_count DESC
          SQL
        end
    end
  end
end
