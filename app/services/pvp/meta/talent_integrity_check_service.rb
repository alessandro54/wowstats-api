module Pvp
  module Meta
    # After talent aggregation, checks that every (bracket, spec) combo
    # has at least one hero-typed talent. Missing hero talents usually means
    # a stale-variant remap failure or a Blizzard patch broke the tree sync.
    class TalentIntegrityCheckService < BaseService
      HERO_MIN = 1

      def initialize(season:, cycle: nil)
        @season = season
        @cycle  = cycle
      end

      def call
        violations = find_violations
        return success(nil, context: { violations: [] }) if violations.empty?

        notify(violations)
        success(nil, context: { violations: violations })
      end

      private

        attr_reader :season, :cycle

        def base_scope
          scope = PvpMetaTalentPopularity.where(pvp_season_id: season.id)
          scope = scope.where(pvp_sync_cycle_id: cycle.id) if cycle
          scope
        end

        def hero_counts
          base_scope
            .where(talent_type: "hero")
            .group(:bracket, :spec_id)
            .count
        end

        def all_pairs
          base_scope
            .distinct
            .pluck(:bracket, :spec_id)
        end

        def find_violations
          present = hero_counts
          all_pairs.filter_map do |(bracket, spec_id)|
            next if present[[ bracket, spec_id ]].to_i >= HERO_MIN

            { bracket: bracket, spec_id: spec_id }
          end
        end

        def notify(violations)
          lines = violations.map { |v| "  • #{v[:bracket]} / spec #{v[:spec_id]}" }.join("\n")
          TelegramNotifier.send(
            "⚠️ <b>Talent integrity error</b>\n" \
            "Season #{season.display_name} — hero talents missing:\n#{lines}"
          )
          log_warn("Hero talents missing for: #{violations.inspect}")
        end
    end
  end
end
