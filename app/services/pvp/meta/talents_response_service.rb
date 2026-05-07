module Pvp
  module Meta
    # rubocop:disable Metrics/ClassLength
    class TalentsResponseService < BaseService
      def initialize(season:, bracket:, spec_id:, locale: "en_US")
        @season   = season
        @bracket  = bracket
        @spec_id  = spec_id
        @locale   = locale
      end

      def call
        records = load_records
        success({ meta: build_meta(records), talents: build_list(records) })
      end

      private

        attr_reader :season, :bracket, :spec_id, :locale

        def load_records
          PvpMetaTalentPopularity.for_meta(season: season, bracket: bracket, spec_id: spec_id)
        end

        def build_list(records)
          zero_talents   = load_zero_fill_talents(records.to_a)
          all_talents    = records.map(&:talent) + zero_talents
          prereqs        = load_prerequisites(all_talents)
          default_points = load_default_points(all_talents)

          records.map { |r| serialize(r, prereqs, default_points) } +
            zero_talents.map { |t| serialize(t, prereqs, default_points) }
        end

        def serialize(record_or_talent, prereqs, default_points)
          TalentSerializer.new(
            record_or_talent,
            locale:         locale,
            prereqs:        prereqs,
            default_points: default_points
          ).call
        end

        def build_meta(records)
          total_weighted = records.sum(&:usage_count).to_i
          total_players  = count_raw_players
          stale_count    = compute_stale_count(records.to_a)
          {
            bracket:         bracket,
            spec_id:         spec_id,
            total_players:   total_players,
            total_weighted:  total_weighted,
            snapshot_at:     records.first&.snapshot_at,
            data_confidence: ConfidenceScore.for(total_players: total_players, stale_count: stale_count),
            stale_count:     stale_count
          }
        end

        def load_zero_fill_talents(records)
          existing_ids  = records.map(&:talent_id)
          covered_nodes = build_covered_nodes(records)
          tree_talents  = load_tree_zero_fill(existing_ids, covered_nodes)
          pvp_talents   = load_pvp_zero_fill(existing_ids, tree_talents)
          tree_talents + pvp_talents
        end

        def build_covered_nodes(records)
          records.each_with_object(Set.new) do |r, set|
            node_id = r.talent.node_id
            set.add([ node_id, r.talent.t("name", locale: locale) ]) if node_id
          end
        end

        def load_tree_zero_fill(existing_ids, covered_nodes)
          scope = Talent.includes(:translations).joins(:talent_spec_assignments)
            .where(talent_spec_assignments: { spec_id: spec_id })
          scope = scope.where.not(id: existing_ids) if existing_ids.any?
          deduplicate_tree_talents(scope.to_a, covered_nodes)
        end

        def deduplicate_tree_talents(talents, covered_nodes)
          talents
            .reject { |t| t.node_id && covered_nodes.include?([ t.node_id, t.t("name", locale: locale) ]) }
            .group_by { |t| [ t.node_id, t.t("name", locale: locale) ] }
            .flat_map { |_, group| group.size == 1 ? group : [ group.max_by { |t| t.icon_url ? 1 : 0 } ] }
        end

        def load_pvp_zero_fill(existing_ids, tree_talents)
          pvp_talent_ids  = CharacterTalent.where(spec_id: spec_id, talent_type: "pvp").distinct.pluck(:talent_id)
          pvp_talent_ids -= existing_ids if existing_ids.any?
          pvp_talent_ids -= tree_talents.map(&:id)
          return [] if pvp_talent_ids.empty?

          Talent.includes(:translations).where(id: pvp_talent_ids).to_a
        end

        def count_raw_players
          PvpLeaderboardEntry
            .joins(:pvp_leaderboard)
            .where(pvp_leaderboards: { pvp_season_id: season.id, bracket: bracket })
            .where(spec_id: spec_id)
            .where.not(specialization_processed_at: nil)
            .select(:character_id).distinct.count
        end

        def load_prerequisites(talents)
          node_ids = talents.filter_map(&:node_id).uniq
          return {} if node_ids.empty?

          TalentPrerequisite
            .where(node_id: node_ids)
            .group_by(&:node_id)
            .transform_values { |ps| ps.map(&:prerequisite_node_id) }
        end

        def load_default_points(talents)
          talent_ids = talents.map(&:id).uniq
          return {} if talent_ids.empty?

          TalentSpecAssignment
            .where(talent_id: talent_ids, spec_id: spec_id)
            .pluck(:talent_id, :default_points)
            .to_h
        end

        def compute_stale_count(records)
          records.count { |r|
            r.talent.talent_type.in?(%w[class spec]) &&
              r.usage_pct.to_f < 1.0 &&
              !r.in_top_build &&
              r.tier == "common"
          }
        end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
