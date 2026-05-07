module Pvp
  module Meta
    class SpecStatsService < BaseService
      def initialize(bracket:, spec_id: nil, limit: 20)
        @bracket = bracket
        @spec_id = spec_id
        @limit   = limit
      end

      def index
        entries = base_entries.where.not(spec_id: nil)
        success({
          bracket:     bracket,
          specs:       spec_distribution(entries),
          snapshot_at: entries.first&.snapshot_at
        })
      end

      def show
        entries = base_entries.where(spec_id: spec_id)
        success({
          spec_id:       spec_id,
          bracket:       bracket,
          total_players: entries.count,
          talent_builds: talent_loadouts(entries),
          hero_talents:  hero_distribution(entries),
          tier_sets:     tier_set_distribution(entries),
          snapshot_at:   entries.first&.snapshot_at
        })
      end

      private

        attr_reader :bracket, :spec_id, :limit

        def base_entries
          PvpLeaderboardEntry
            .latest_snapshot_for_bracket(bracket)
            .includes(:character)
        end

        def spec_distribution(entries)
          total = entries.count.to_f
          return [] if total.zero?

          entries
            .group(:spec_id)
            .count
            .map { |sid, count| spec_row(sid, count, total) }
            .sort_by { |s| -s[:usage_pct] }
        end

        def spec_row(sid, count, total)
          {
            spec_id:   sid,
            spec_slug: Wow::Catalog::SPECS[sid][:spec_slug],
            count:     count,
            usage_pct: pct(count, total)
          }
        end

        def talent_loadouts(entries)
          total = entries.count.to_f
          return [] if total.zero?

          loadout_counts(entries)
            .map { |code, count| { loadout_code: code, count: count, usage_pct: pct(count, total) } }
            .sort_by { |b| -b[:usage_pct] }
            .first(limit)
        end

        def loadout_counts(entries)
          entries
            .joins(:character)
            .where("characters.spec_talent_loadout_codes -> CAST(pvp_leaderboard_entries.spec_id AS TEXT) IS NOT NULL")
            .group(Arel.sql("characters.spec_talent_loadout_codes ->> CAST(pvp_leaderboard_entries.spec_id AS TEXT)"))
            .count
        end

        def hero_distribution(entries)
          total = entries.count.to_f
          return [] if total.zero?

          entries
            .where.not(hero_talent_tree_id: nil)
            .group(:hero_talent_tree_id, :hero_talent_tree_name)
            .count
            .map { |(tree_id, tree_name), count|
              {
                hero_talent_tree_id:   tree_id,
                hero_talent_tree_name: tree_name,
                count:                 count,
                usage_pct:             pct(count, total)
              }
            }
            .sort_by { |h| -h[:usage_pct] }
        end

        def tier_set_distribution(entries)
          total = entries.count.to_f
          return [] if total.zero?

          entries
            .where.not(tier_set_id: nil)
            .group(:tier_set_id, :tier_set_name, :tier_set_pieces, :tier_4p_active)
            .count
            .map { |(set_id, set_name, pieces, is_4p), count|
              {
                tier_set_id:     set_id,
                tier_set_name:   set_name,
                tier_set_pieces: pieces,
                tier_4p_active:  is_4p,
                count:           count,
                usage_pct:       pct(count, total)
              }
            }
            .sort_by { |t| -t[:usage_pct] }
        end

        def pct(count, total)
          (count / total * 100).round(2)
        end
    end
  end
end
