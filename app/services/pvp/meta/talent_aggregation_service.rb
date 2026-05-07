module Pvp
  module Meta
    # rubocop:disable Metrics/ClassLength
    class TalentAggregationService < BaseService
      include AggregationSql

      TOP_N = Pvp::SyncConfig::META_TOP_N

      BIS_THRESHOLD         = TalentTierClassifier::BIS_THRESHOLD
      SITUATIONAL_THRESHOLD = TalentTierClassifier::SITUATIONAL_THRESHOLD

      # Player weight tiers — elite players' choices count more.
      # Elite (3x):       top 15% rating AND winrate > 60%
      # Competitive (2x): top 50% rating OR  winrate > 55%
      # Standard (1x):    everyone else
      ELITE_RATING_PCT       = 0.15
      ELITE_WINRATE          = 60.0
      COMPETITIVE_RATING_PCT = 0.50
      COMPETITIVE_WINRATE    = 55.0

      WEIGHT_ELITE       = 3.0
      WEIGHT_COMPETITIVE = 2.0
      WEIGHT_STANDARD    = 1.0

      def initialize(season:, top_n: TOP_N, cycle: nil)
        @season = season
        @top_n  = top_n
        @cycle  = cycle
      end

      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      def call
        rows    = execute_query
        rows    = merge_ranked_rows(rows)
        rows    = merge_stale_variants(rows)
        rows    = drop_unresolvable_stale(rows)
        rows    = apply_budget_tiers(rows)
        records = build_records(rows)

        if records.any?
          if @cycle
            ApplicationRecord.transaction do
              PvpMetaTalentPopularity.where(pvp_sync_cycle_id: @cycle.id).delete_all
              # rubocop:disable Rails/SkipsModelValidations
              PvpMetaTalentPopularity.insert_all!(records)
              # rubocop:enable Rails/SkipsModelValidations
            end
          else
            # rubocop:disable Rails/SkipsModelValidations
            PvpMetaTalentPopularity.upsert_all(
              records,
              unique_by:   %i[pvp_season_id bracket spec_id talent_id],
              update_only: %i[talent_type usage_count usage_pct in_top_build top_build_rank tier snapshot_at]
            )
            # rubocop:enable Rails/SkipsModelValidations

            # Remove stale rank-variant rows that were merged into a primary record.
            # Use per-(bracket, spec_id) kept_ids so a stale talent that survives in
            # one spec's data cannot prevent its deletion from another spec's records.
            kept_ids_by_pair = records.each_with_object(Hash.new { |h, k| h[k] = [] }) do |r, h|
              h[[ r[:bracket], r[:spec_id] ]] << r[:talent_id]
            end
            kept_ids_by_pair.each do |(bracket, spec_id), ids|
              PvpMetaTalentPopularity
                .where(pvp_season_id: season.id, bracket: bracket, spec_id: spec_id)
                .where(pvp_sync_cycle_id: nil)
                .where.not(talent_id: ids)
                .delete_all
            end
          end
        end

        success(records.size, context: { count: records.size })
      rescue => e
        Sentry.capture_exception(e, extra: { service: self.class.name, season_id: season.id })
        failure(e, captured: true)
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      private

        attr_reader :season, :top_n, :cycle

        # Override: filters on specialization_processed_at (not equipment_processed_at)
        # and adds wins/losses/weight columns needed for the weighted talent query.
        # rubocop:disable Metrics/MethodLength
        def top_chars_cte(bracket: nil)
          if bracket
            distinct_on  = "e.character_id"
            order_by     = "e.character_id, e.rating DESC"
            bracket_cond = "AND l.bracket = :bracket"
          else
            distinct_on  = "l.bracket, e.character_id"
            order_by     = "l.bracket, e.character_id, e.rating DESC"
            bracket_cond = ""
          end

          <<~SQL
            latest_per_char AS (
              SELECT DISTINCT ON (#{distinct_on})
                e.character_id,
                l.bracket,
                e.spec_id,
                e.rating,
                e.wins,
                e.losses
              FROM pvp_leaderboard_entries e
              JOIN pvp_leaderboards l ON l.id = e.pvp_leaderboard_id
              WHERE l.pvp_season_id = :season_id
                #{bracket_cond}
                AND e.spec_id IS NOT NULL
                AND e.specialization_processed_at IS NOT NULL
              ORDER BY #{order_by}
            ),
            ranked AS (
              SELECT *,
                RANK() OVER (PARTITION BY bracket, spec_id ORDER BY rating DESC) AS rk,
                COUNT(*) OVER (PARTITION BY bracket, spec_id) AS spec_total
              FROM latest_per_char
            ),
            top_chars AS (
              SELECT *,
                CASE
                  WHEN rk <= spec_total * #{ELITE_RATING_PCT}
                    AND wins * 100.0 / NULLIF(wins + losses, 0) > #{ELITE_WINRATE}
                  THEN #{WEIGHT_ELITE}
                  WHEN rk <= spec_total * #{COMPETITIVE_RATING_PCT}
                    OR wins * 100.0 / NULLIF(wins + losses, 0) > #{COMPETITIVE_WINRATE}
                  THEN #{WEIGHT_COMPETITIVE}
                  ELSE #{WEIGHT_STANDARD}
                END AS weight
              FROM ranked WHERE rk <= :top_n
            )
          SQL
        end
        # rubocop:enable Metrics/MethodLength

        # Builds the top-build CTEs: fingerprint each character's full talent loadout,
        # find the single most common loadout per bracket/spec, expose its talent ids,
        # and compute the modal rank each talent is taken at within that top build.
        def top_build_cte
          <<~SQL
            char_builds AS (
              SELECT
                t.bracket,
                t.spec_id,
                t.character_id,
                t.weight,
                array_agg(ct.talent_id ORDER BY ct.talent_id) AS build
              FROM top_chars t
              JOIN character_talents ct ON ct.character_id = t.character_id AND ct.spec_id = t.spec_id AND ct.rank > 0
              GROUP BY t.bracket, t.spec_id, t.character_id, t.weight
            ),
            build_counts AS (
              SELECT bracket, spec_id, build, SUM(weight) AS cnt
              FROM char_builds
              GROUP BY bracket, spec_id, build
            ),
            best_build AS (
              SELECT DISTINCT ON (bracket, spec_id) bracket, spec_id, build
              FROM build_counts
              ORDER BY bracket, spec_id, cnt DESC
            ),
            top_build_talents AS (
              SELECT bracket, spec_id, unnest(build) AS talent_id
              FROM best_build
            ),
            best_build_chars AS (
              SELECT cb.character_id, cb.bracket, cb.spec_id
              FROM char_builds cb
              JOIN best_build bb
                ON bb.bracket = cb.bracket
               AND bb.spec_id = cb.spec_id
               AND bb.build   = cb.build
            ),
            top_build_talent_ranks AS (
              SELECT
                t.bracket,
                t.spec_id,
                ct.talent_id,
                ct.rank,
                SUM(t.weight) AS cnt
              FROM top_chars t
              JOIN character_talents ct ON ct.character_id = t.character_id AND ct.spec_id = t.spec_id AND ct.rank > 0
              GROUP BY t.bracket, t.spec_id, ct.talent_id, ct.rank
            ),
            top_build_modal_rank AS (
              SELECT DISTINCT ON (bracket, spec_id, talent_id)
                bracket, spec_id, talent_id, rank AS top_build_rank
              FROM top_build_talent_ranks
              ORDER BY bracket, spec_id, talent_id, cnt DESC
            )
          SQL
        end

        def execute_query
          run_per_bracket(season_brackets) do |bracket|
            ApplicationRecord.connection.select_all(
              ApplicationRecord.sanitize_sql_array([
                talent_sql(bracket),
                { season_id: season.id, top_n: top_n, bracket: bracket,
                  bis_pct: BIS_THRESHOLD, sit_pct: SITUATIONAL_THRESHOLD }
              ])
            )
          end
        end

        # rubocop:disable Metrics/MethodLength
        def talent_sql(bracket)
          <<~SQL
            WITH #{top_chars_cte(bracket: bracket)},
            spec_totals AS (
              SELECT bracket, spec_id, SUM(weight) AS total
              FROM top_chars
              GROUP BY bracket, spec_id
            ),
            talent_usage AS (
              SELECT
                t.bracket,
                t.spec_id,
                ct.talent_id,
                tal.talent_type,
                COALESCE(tsa.default_points, 0) AS default_points,
                SUM(t.weight)::int                              AS usage_count,
                ROUND(SUM(t.weight) * 100.0 / st.total, 4)     AS usage_pct,
                NOW()                                   AS snapshot_at
              FROM top_chars t
              JOIN character_talents ct ON ct.character_id = t.character_id AND ct.spec_id = t.spec_id
              JOIN talents tal ON tal.id = ct.talent_id
              LEFT JOIN talent_spec_assignments tsa
                ON tsa.talent_id = ct.talent_id AND tsa.spec_id = t.spec_id
              JOIN spec_totals st
                ON st.bracket = t.bracket AND st.spec_id = t.spec_id
              GROUP BY t.bracket, t.spec_id, ct.talent_id, tal.talent_type, tsa.default_points, st.total
            ),
            #{top_build_cte}
            SELECT
              tu.bracket,
              tu.spec_id,
              tu.talent_id,
              tu.talent_type,
              tu.default_points,
              tu.usage_count,
              tu.usage_pct,
              tu.snapshot_at,
              EXISTS (
                SELECT 1 FROM top_build_talents tbt
                WHERE tbt.bracket = tu.bracket
                  AND tbt.spec_id = tu.spec_id
                  AND tbt.talent_id = tu.talent_id
              ) AS in_top_build,
              COALESCE(tbmr.top_build_rank, 0) AS top_build_rank,
              CASE
                WHEN tu.default_points > 0      THEN 'bis'
                WHEN tu.usage_pct > :bis_pct     THEN 'bis'
                WHEN tu.usage_pct > :sit_pct     THEN 'situational'
                ELSE 'common'
              END AS tier
            FROM talent_usage tu
            LEFT JOIN top_build_modal_rank tbmr
              ON  tbmr.bracket   = tu.bracket
              AND tbmr.spec_id   = tu.spec_id
              AND tbmr.talent_id = tu.talent_id
            ORDER BY tu.bracket, tu.spec_id, tu.talent_type, tu.usage_count DESC
          SQL
        end
        # rubocop:enable Metrics/MethodLength

        # ── Ranked-variant deduplication ────────────────────────────────
        #
        # Blizzard assigns a distinct talent_id per rank of a talent, so the same
        # tree node can produce multiple SQL rows. Merge them into one row per
        # (bracket, spec_id, node_id, name) by summing counts/pcts.
        #
        # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        def merge_ranked_rows(rows)
          return rows if rows.empty?

          talent_ids = rows.map { |r| r["talent_id"] }.uniq

          node_ids_by_talent = Talent.where(id: talent_ids).pluck(:id, :node_id).to_h
          names_by_talent    = Translation
            .where(translatable_type: "Talent", translatable_id: talent_ids, key: "name", locale: "en_US")
            .pluck(:translatable_id, :value)
            .to_h

          rows
            .group_by do |r|
              node_id = node_ids_by_talent[r["talent_id"]]
              node_id ? [ r["bracket"], r["spec_id"], node_id, names_by_talent[r["talent_id"]] ]
                      : r["talent_id"]
            end
            .flat_map do |_key, group|
              next group if group.size == 1
              next group if node_ids_by_talent[group.first["talent_id"]].nil?

              # Use the highest-usage rank variant as the primary; do not sum usage_pct/count
              # because each character has a separate CharacterTalent record per rank variant,
              # so summing would multiply-count the same players (e.g. 3× for max_rank=3).
              primary = group.max_by { |r| r["usage_pct"].to_f }.dup
              primary["default_points"] = group.map { |r| r["default_points"].to_i }.max
              primary["in_top_build"]   = group.any? { |r| r["in_top_build"] }
              non_zero                  = group.map { |r| r["top_build_rank"].to_i }.select { |r| r > 0 }
              primary["top_build_rank"] = non_zero.max || 0
              [ primary ]
            end
        end

        # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

        # ── Cross-node stale-variant deduplication ───────────────────────
        #
        # Handles the case where a talent was reworked (blizzard_id changed) and
        # the old talent record survives in CharacterTalent data. The old record
        # has the same name as the new one but a different node_id and no
        # TalentSpecAssignment for the current spec. Merge its usage into the
        # canonical (TSA-assigned) entry and discard the stale one.
        #
        # When no canonical appears in the current rows (e.g. no player uses the
        # new blizzard_id yet in this bracket), remap the stale row to the
        # canonical talent_id so max_rank/spell_id come from the correct record.
        #
        # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        def merge_stale_variants(rows)
          return rows if rows.empty?

          talent_ids    = rows.map { |r| r["talent_id"] }.uniq
          names         = Translation
            .where(translatable_type: "Talent", translatable_id: talent_ids, key: "name", locale: "en_US")
            .pluck(:translatable_id, :value).to_h
          spec_ids      = rows.map { |r| r["spec_id"] }.uniq
          assigned_ids  = TalentSpecAssignment
            .where(talent_id: talent_ids, spec_id: spec_ids)
            .pluck(:talent_id, :spec_id)
            .to_set

          # Canonical talent_id lookup for stale rows whose canonical is not in
          # the current rows. Keyed by [spec_id, name] → single assigned talent_id.
          # Skips ambiguous cases (multiple assigned talents with the same name = choice node).
          canonical_by_spec_name = build_canonical_tid_map(spec_ids, names.values.uniq.compact)

          rows
            .group_by { |r| [ r["bracket"], r["spec_id"], names[r["talent_id"]] ] }
            .flat_map do |(_bracket, spec_id, name), group|
              canonical = group.select { |r| assigned_ids.include?([ r["talent_id"], spec_id ]) }

              # Happy path: exactly one canonical in current rows — discard stale.
              next canonical if canonical.size == 1

              # Multiple canonicals (real choice node) or all canonical: pass through.
              next group if canonical.size > 1 || canonical.size == group.size

              # All entries are stale (no TSA match in current rows).
              # Remap the highest-usage row to the canonical talent_id so that
              # max_rank/spell_id come from the correct record.
              if name
                canonical_tid = canonical_by_spec_name[[ spec_id, name ]]
                if canonical_tid
                  remapped = group.max_by { |r| r["usage_pct"].to_f }.dup
                  remapped["talent_id"] = canonical_tid
                  next [ remapped ]
                end
              end

              # No assigned canonical found: pass through unchanged.
              group
            end
        end
        # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

        # Returns { [spec_id, name] => talent_id } for names that map to exactly
        # one assigned talent per spec (skips choice nodes with multiple assignments).
        # rubocop:disable Metrics/AbcSize
        def build_canonical_tid_map(spec_ids, names)
          return {} if names.empty?

          assigned_pairs = TalentSpecAssignment.where(spec_id: spec_ids).pluck(:talent_id, :spec_id)
          tid_names      = load_tid_names(assigned_pairs.map(&:first).uniq)

          assigned_pairs
            .select { |(tid, _)| names.include?(tid_names[tid]) }
            .group_by { |(tid, sid)| [ sid, tid_names[tid] ] }
            .each_with_object({}) do |((sid, name), pairs), h|
              next unless pairs.size == 1

              h[[ sid, name ]] = pairs.first.first
            end
        end
        # rubocop:enable Metrics/AbcSize

        def load_tid_names(talent_ids)
          Translation
            .where(translatable_type: "Talent", translatable_id: talent_ids, key: "name", locale: "en_US")
            .pluck(:translatable_id, :value).to_h
        end

        # ── Drop unresolvable stale talents ─────────────────────────────
        #
        # Removes rows for talents that have no TalentSpecAssignment for the
        # current spec AND no icon_url. These are definitively obsolete entries
        # (old blizzard_ids from pre-rework data) with no canonical partner to
        # merge into. Keeping them produces broken talent cards in the UI.
        #
        # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        def drop_unresolvable_stale(rows)
          return rows if rows.empty?

          talent_ids   = rows.map { |r| r["talent_id"] }.uniq
          spec_ids     = rows.map { |r| r["spec_id"] }.uniq
          assigned_ids = TalentSpecAssignment
            .where(talent_id: talent_ids, spec_id: spec_ids)
            .pluck(:talent_id, :spec_id)
            .to_set
          icon_ids     = Talent.where(id: talent_ids).where.not(icon_url: [ nil, "" ]).pluck(:id).to_set

          rows.reject do |r|
            tid      = r["talent_id"]
            spec_id  = r["spec_id"]
            !assigned_ids.include?([ tid, spec_id ]) && !icon_ids.include?(tid)
          end
        end
        # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

        def apply_budget_tiers(rows)
          return rows if rows.empty?

          TalentTierClassifier.new(
            rows:        rows,
            prereqs:     load_prerequisite_graph,
            talent_info: load_talent_info(rows)
          ).call
        end

        # ── Data loading ────────────────────────────────────────────────

        def load_prerequisite_graph
          TalentPrerequisite.pluck(:node_id, :prerequisite_node_id)
            .each_with_object(Hash.new { |h, k| h[k] = [] }) do |(node_id, prereq_id), h|
              h[node_id] << prereq_id
            end
        end

        # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        def load_talent_info(rows)
          talent_ids = rows.map { |r| r["talent_id"] }.uniq
          return {} if talent_ids.empty?

          talents  = Talent.where(id: talent_ids).pluck(:id, :node_id, :max_rank)
          spec_ids = rows.map { |r| r["spec_id"] }.uniq
          defaults = TalentSpecAssignment
            .where(talent_id: talent_ids, spec_id: spec_ids)
            .pluck(:talent_id, :spec_id, :default_points)

          default_map = defaults.each_with_object({}) do |(tid, sid, dp), h|
            h[[ tid, sid ]] = dp
          end

          talents.each_with_object({}) do |(id, node_id, max_rank), h|
            dp = default_map.select { |(tid, _), _| tid == id }.values.max || 0
            h[id] = { node_id: node_id, max_rank: max_rank || 1, default_points: dp }
          end
        end
        # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

        def build_records(rows)
          now = Time.current
          rows.map do |r|
            {
              pvp_season_id:     season.id,
              bracket:           r["bracket"],
              spec_id:           r["spec_id"],
              talent_id:         r["talent_id"],
              talent_type:       r["talent_type"],
              usage_count:       r["usage_count"],
              usage_pct:         r["usage_pct"],
              in_top_build:      r["in_top_build"],
              top_build_rank:    r["top_build_rank"].to_i,
              tier:              r["tier"],
              snapshot_at:       r["snapshot_at"] || now,
              created_at:        now,
              updated_at:        now,
              pvp_sync_cycle_id: @cycle&.id
            }
          end
        end
    end
  end
end
# rubocop:enable Metrics/ClassLength
