module Pvp
  module Meta
    # Compares the current ranking against a cached previous snapshot and
    # returns the distribution rows annotated with `rank_change` (positive =
    # climbed). Seeds the snapshot on first call so subsequent runs have a
    # baseline. Skipped in development (no snapshots, all `nil`).
    class RankChangeService < BaseService
      RANK_SNAPSHOT_TTL = 6.hours

      def initialize(distribution:, season:, bracket:, region:, role:)
        @distribution = distribution
        @season       = season
        @bracket      = bracket
        @region       = region
        @role         = role
      end

      def call
        return success(distribution.map { |r| r.merge(rank_change: nil) }) if Rails.env.development?

        current_ranks = distribution.each_with_index.to_h { |row, i| [ row[:spec_id], i + 1 ] }
        prev_ranks    = load_or_seed_snapshot(current_ranks)

        success(distribution.map { |row| with_rank_change(row, prev_ranks, current_ranks) })
      end

      private

        attr_reader :distribution, :season, :bracket, :region, :role

        def with_rank_change(row, prev_ranks, current_ranks)
          prev_rank = prev_ranks&.dig(row[:spec_id])
          rank_change = prev_rank ? prev_rank - current_ranks[row[:spec_id]] : nil
          row.merge(rank_change: rank_change)
        end

        def snap_key
          "pvp_meta/rank_snapshot/#{season.blizzard_id}/#{bracket}/#{region || 'all'}/#{role || 'all'}"
        end

        def load_or_seed_snapshot(current_ranks)
          prev = Rails.cache.read(snap_key)
          Rails.cache.write(snap_key, current_ranks, expires_in: RANK_SNAPSHOT_TTL) if prev.nil?
          prev
        end
    end
  end
end
