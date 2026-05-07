module Pvp
  module Meta
    # Shared lifecycle for non-talent meta aggregations (item / enchant / gem).
    # Subclass and define:
    #   * model_class
    #   * snapshot_keys → Array<Symbol> of columns identifying a popularity row
    #   * popularity_sql(bracket) → SQL string returning rows
    #   * record_fields(row) → Hash of domain-specific fields to merge into the record
    class AggregationBase < BaseService
      include AggregationSql

      TOP_N = ENV.fetch("PVP_META_TOP_N", 1000).to_i

      def initialize(season:, top_n: TOP_N, cycle: nil)
        @season = season
        @top_n  = top_n
        @cycle  = cycle
      end

      def call
        prev_map = snapshot_prev_values
        rows     = execute_query
        records  = build_records(rows, prev_map)
        persist_records(records)
        success(records.size, context: { count: records.size })
      rescue => e
        Sentry.capture_exception(e, extra: { service: self.class.name, season_id: season.id })
        failure(e, captured: true)
      end

      private

        attr_reader :season, :top_n, :cycle

        # Subclass hooks ─────────────────────────────────────────────────
        def model_class       = raise NotImplementedError
        def snapshot_keys     = raise NotImplementedError
        def popularity_sql(_) = raise NotImplementedError
        def record_fields(_)  = raise NotImplementedError

        # Shared pipeline ────────────────────────────────────────────────
        def execute_query
          run_per_bracket(season_brackets) do |bracket|
            ApplicationRecord.connection.select_all(
              ApplicationRecord.sanitize_sql_array([
                popularity_sql(bracket),
                { season_id: season.id, top_n: top_n, bracket: bracket }
              ])
            )
          end
        end

        def snapshot_prev_values
          model_class
            .where(pvp_season_id: season.id)
            .pluck(*snapshot_keys, :usage_pct)
            .each_with_object({}) do |values, h|
              h[snapshot_key_from(values[0..-2])] = values.last
            end
        end

        def snapshot_key_from(values)
          snapshot_keys.zip(values).map { |k, v| coerce_snapshot_value(k, v) }
        end

        def coerce_snapshot_value(key, value)
          case key
          when :spec_id, :item_id, :enchantment_id, :talent_id then value.to_i
          else value
          end
        end

        def build_records(rows, prev_map)
          now = Time.current
          rows.map { |r| build_record(r, prev_map, now) }
        end

        def build_record(row, prev_map, now)
          fields = record_fields(row)
          prev_key = snapshot_keys.map { |k| coerce_snapshot_value(k, fields[k] || row[k.to_s]) }
          {
            pvp_season_id:     season.id,
            usage_count:       row["usage_count"],
            usage_pct:         row["usage_pct"],
            prev_usage_pct:    prev_map[prev_key],
            snapshot_at:       row["snapshot_at"] || now,
            created_at:        now,
            updated_at:        now,
            pvp_sync_cycle_id: @cycle&.id
          }.merge(fields)
        end

        def persist_records(records)
          ApplicationRecord.transaction do
            # rubocop:disable Rails/SkipsModelValidations
            scope = @cycle ?
              model_class.where(pvp_sync_cycle_id: @cycle.id) :
              model_class.where(pvp_season_id: season.id)
            scope.delete_all
            model_class.insert_all!(records) if records.any?
            # rubocop:enable Rails/SkipsModelValidations
          end
        end
    end
  end
end
