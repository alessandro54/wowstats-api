class Api::V1::Pvp::Meta::TalentsController < Api::V1::BaseController
  include MetaParams

  def index
    cache_key = meta_cache_key("talents", bracket_param, spec_id_param, locale_param)
    json = meta_cache_fetch(cache_key) { serialize_talents_response }
    render json: json
    set_cache_headers
  end

  private

    def serialize_talents_response
      season  = meta_season_for(PvpMetaTalentPopularity)
      records = load_talent_records(season)
      {
        meta:    build_talents_meta(records),
        talents: build_talents_list(records)
      }
    end

    def load_talent_records(season)
      PvpMetaTalentPopularity.for_meta(
        season: season, bracket: bracket_param, spec_id: spec_id_param
      )
    end

    def build_talents_list(records)
      zero_talents   = load_zero_fill_talents(records.to_a)
      all_talents    = records.map(&:talent) + zero_talents
      prereqs        = load_prerequisites(all_talents)
      default_points = load_default_points(all_talents)
      records.map { |r| serialize(r, prereqs, default_points) } +
        zero_talents.map { |t| serialize_zero(t, prereqs, default_points) }
    end

    def build_talents_meta(records)
      total_weighted = records.sum(&:usage_count).to_i
      total_players  = count_raw_players
      stale_count    = compute_stale_count(records.to_a)
      {
        bracket:         bracket_param,
        spec_id:         spec_id_param,
        total_players:   total_players,
        total_weighted:  total_weighted,
        snapshot_at:     records.first&.snapshot_at,
        data_confidence: compute_confidence(total_players, stale_count),
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
        set.add([ node_id, r.talent.t("name", locale: locale_param) ]) if node_id
      end
    end

    def load_tree_zero_fill(existing_ids, covered_nodes)
      scope = Talent.includes(:translations).joins(:talent_spec_assignments)
        .where(talent_spec_assignments: { spec_id: spec_id_param })
      scope = scope.where.not(id: existing_ids) if existing_ids.any?
      deduplicate_tree_talents(scope.to_a, covered_nodes)
    end

    def deduplicate_tree_talents(talents, covered_nodes)
      talents
        .reject { |t| t.node_id && covered_nodes.include?([ t.node_id, t.t("name", locale: locale_param) ]) }
        .group_by { |t| [ t.node_id, t.t("name", locale: locale_param) ] }
        .flat_map { |_, group| group.size == 1 ? group : [ group.max_by { |t| t.icon_url ? 1 : 0 } ] }
    end

    def load_pvp_zero_fill(existing_ids, tree_talents)
      pvp_talent_ids  = CharacterTalent.where(spec_id: spec_id_param, talent_type: "pvp").distinct.pluck(:talent_id)
      pvp_talent_ids -= existing_ids if existing_ids.any?
      pvp_talent_ids -= tree_talents.map(&:id)
      return [] if pvp_talent_ids.empty?

      Talent.includes(:translations).where(id: pvp_talent_ids).to_a
    end

    def count_raw_players
      PvpLeaderboardEntry
        .joins(:pvp_leaderboard)
        .where(pvp_leaderboards: { pvp_season_id: meta_season_for(PvpMetaTalentPopularity).id, bracket: bracket_param })
        .where(spec_id: spec_id_param)
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
        .where(talent_id: talent_ids, spec_id: spec_id_param)
        .pluck(:talent_id, :default_points)
        .to_h
    end

    def serialize(record, prereqs, default_points)
      t = record.talent
      {
        id:             record.id,
        talent:         serialize_talent_fields(t, record.talent_type, prereqs, default_points),
        usage_count:    record.usage_count,
        usage_pct:      record.usage_pct.to_f,
        in_top_build:   record.in_top_build,
        top_build_rank: record.top_build_rank,
        tier:           record.tier,
        snapshot_at:    record.snapshot_at
      }
    end

    def serialize_zero(talent, prereqs, default_points)
      dp = default_points[talent.id] || 0
      {
        id:             nil,
        talent:         serialize_talent_fields(talent, talent.talent_type, prereqs, default_points),
        usage_count:    0,
        usage_pct:      0.0,
        in_top_build:   false,
        top_build_rank: 0,
        tier:           dp > 0 ? "bis" : "common",
        snapshot_at:    nil
      }
    end

    def serialize_talent_fields(t, talent_type, prereqs, default_points)
      {
        id:                    t.id,
        blizzard_id:           t.blizzard_id,
        name:                  t.t("name", locale: locale_param),
        description:           t.t("description", locale: locale_param),
        talent_type:           talent_type,
        spell_id:              t.spell_id,
        node_id:               t.node_id,
        display_row:           t.display_row,
        display_col:           t.display_col,
        max_rank:              t.max_rank,
        icon_url:              t.icon_url,
        default_points:        default_points[t.id] || 0,
        prerequisite_node_ids: prereqs[t.node_id] || []
      }
    end

    def compute_stale_count(records)
      records.count { |r|
        r.talent_type.in?(%w[class spec]) &&
          r.usage_pct.to_f < 1.0 &&
          !r.in_top_build &&
          r.tier == "common"
      }
    end

    def compute_confidence(total_players, stale_count)
      if total_players >= 100 && stale_count == 0
        "high"
      elsif total_players >= 30 && stale_count <= 5
        "medium"
      else
        "low"
      end
    end
end
