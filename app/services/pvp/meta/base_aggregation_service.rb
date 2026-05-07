module Pvp
  module Meta
    # Template for popularity aggregation services that follow the standard
    # snapshot → query → build → persist flow. Subclasses provide:
    #   - .popularity_model — the AR model to write into
    #   - .key_columns      — identity tuple columns, e.g. %i[bracket spec_id slot item_id]
    #   - #aggregation_sql  — the bracket/spec/slot grouping SQL (uses top_chars_cte)
    #   - #row_attrs(row)   — record-specific column hash (e.g., item_id, slot)
    #
    # See ItemAggregationService for the canonical example.
    class BaseAggregationService < BaseService
      include AggregationSql

      TOP_N = Pvp::SyncConfig::META_TOP_N

      class << self
        attr_reader :popularity_model, :key_columns

        def aggregates(model:, key_columns:)
          @popularity_model = model
          @key_columns      = key_columns
        end
      end

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

        def popularity_model = self.class.popularity_model
        def key_columns      = self.class.key_columns

        def execute_query
          ApplicationRecord.connection.select_all(
            ApplicationRecord.sanitize_sql_array([ aggregation_sql, { season_id: season.id, top_n: top_n } ])
          )
        end

        def persist_records(records)
          ApplicationRecord.transaction do
            scope = @cycle ? popularity_model.where(pvp_sync_cycle_id: @cycle.id)
                           : popularity_model.where(pvp_season_id: season.id)
            # rubocop:disable Rails/SkipsModelValidations
            scope.delete_all
            popularity_model.insert_all!(records) if records.any?
            # rubocop:enable Rails/SkipsModelValidations
          end
        end

        def snapshot_prev_values
          cols = key_columns + [ :usage_pct ]
          popularity_model
            .where(pvp_season_id: season.id)
            .pluck(*cols)
            .each_with_object({}) do |row, h|
              *key_parts, pct = row
              h[normalize_key(key_parts)] = pct
            end
        end

        def normalize_key(parts)
          parts.map.with_index do |val, i|
            key_columns[i].to_s.end_with?("_id") || key_columns[i] == :spec_id ? val.to_i : val
          end
        end

        def build_records(rows, prev_map = {})
          now = Time.current
          rows.map { |r| base_attrs(r, now).merge(row_attrs(r), prev_usage_pct: lookup_prev(r, prev_map)) }
        end

        def base_attrs(row, now)
          {
            pvp_season_id:     season.id,
            bracket:           row["bracket"],
            spec_id:           row["spec_id"],
            usage_count:       row["usage_count"],
            usage_pct:         row["usage_pct"],
            snapshot_at:       row["snapshot_at"] || now,
            created_at:        now,
            updated_at:        now,
            pvp_sync_cycle_id: @cycle&.id
          }
        end

        def lookup_prev(row, prev_map)
          parts = key_columns.map { |col| row[col.to_s] }
          prev_map[normalize_key(parts)]
        end
    end
  end
end
