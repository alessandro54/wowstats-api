module Pvp
  module Meta
    # rubocop:disable Metrics/ClassLength
    class TalentAggregationService < BaseService
      include AggregationSql

      TOP_N = Pvp::SyncConfig::META_TOP_N

      # Fallback thresholds used when Jenks cannot find natural breaks
      # (e.g. fewer than k+1 distinct usage values in the group).
      BIS_THRESHOLD         = 75.0
      SITUATIONAL_THRESHOLD = 50.0
      COMMON_THRESHOLD      = 35.0

      # Budget per tree type (talent points available)
      TREE_BUDGETS = { "class" => 34, "spec" => 34, "hero" => 10 }.freeze
      HERO_OFF_TREE_THRESHOLD = 30.0

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

        # Override to filter on specialization_processed_at instead of equipment_processed_at
        def top_chars_cte
          <<~SQL
            latest_per_char AS (
              SELECT DISTINCT ON (l.bracket, e.character_id)
                e.character_id,
                l.bracket,
                e.spec_id,
                e.rating,
                e.wins,
                e.losses
              FROM pvp_leaderboard_entries e
              JOIN pvp_leaderboards l ON l.id = e.pvp_leaderboard_id
              WHERE l.pvp_season_id = :season_id
                AND e.spec_id IS NOT NULL
                AND e.specialization_processed_at IS NOT NULL
              ORDER BY l.bracket, e.character_id, e.rating DESC
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

        # rubocop:disable Metrics/MethodLength
        def execute_query
          sql = <<~SQL
            WITH #{top_chars_cte},
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

          ApplicationRecord.connection.execute("SET LOCAL work_mem = '256MB'")
          ApplicationRecord.connection.select_all(
            ApplicationRecord.sanitize_sql_array(
              [ sql, {
                season_id: season.id,
                top_n:     top_n,
                bis_pct:   BIS_THRESHOLD,
                sit_pct:   SITUATIONAL_THRESHOLD
              } ]
            )
          )
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

          rows
            .group_by { |r| [ r["bracket"], r["spec_id"], names[r["talent_id"]] ] }
            .flat_map do |(_bracket, spec_id, _name), group|
              next group if group.size == 1

              canonical = group.select { |r| assigned_ids.include?([ r["talent_id"], spec_id ]) }
              stale     = group.reject { |r| assigned_ids.include?([ r["talent_id"], spec_id ]) }

              # Only discard stale when exactly one canonical entry exists; otherwise pass through unchanged.
              next group unless canonical.size == 1

              # Do not sum stale usage into canonical — re-processed characters contribute to both
              # old and new CharacterTalent records, so summing would double-count and exceed 100%.
              # Just keep the canonical entry and discard the stale ones.
              canonical
            end
        end
        # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

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

        # ── Tier assignment ──────────────────────────────────────────────
        #
        # For each (bracket, spec, talent_type) group:
        #
        #   Hero trees  → selected sub-tree all BiS, off-tree situational/common
        #   Class/Spec  → in_top_build nodes → BiS (budget always fully spent because
        #                 the top-build fingerprint is a real player's complete 34-pt build,
        #                 so all prerequisite nodes are included automatically);
        #                 non-top-build nodes with pct ≥ SITUATIONAL_THRESHOLD → situational
        #
        # Choice nodes: primary talent gets node tier, alternatives demoted one level.
        #
        def apply_budget_tiers(rows)
          return rows if rows.empty?

          @prereqs = load_prerequisite_graph
          @talent_info = load_talent_info(rows)

          groups = rows.group_by { |r| [ r["bracket"], r["spec_id"], r["talent_type"] ] }

          groups.each do |(_, _, talent_type), group_rows|
            budget = TREE_BUDGETS[talent_type]

            unless budget
              assign_pvp_tiers(group_rows)
              next
            end

            node_rows = build_node_rows(group_rows)

            if talent_type == "hero"
              assign_hero_tiers(node_rows)
            else
              assign_tree_tiers(node_rows, budget)
            end
          end

          rows
        end

        # ── Node grouping ───────────────────────────────────────────────

        # Groups SQL rows by node_id. Talents on the same node are choice alternatives.
        def build_node_rows(group_rows)
          node_rows = Hash.new { |h, k| h[k] = [] }
          group_rows.each do |r|
            info = @talent_info[r["talent_id"]]
            next unless info&.[](:node_id)

            node_rows[info[:node_id]] << r
          end
          node_rows
        end

        # The highest-usage talent on a node (the "pick" for choice nodes).
        def primary_talent(node_group)
          node_group.max_by { |r| r["usage_pct"].to_f }
        end

        # ── Class/Spec tree tier assignment ─────────────────────────────

        # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        # BiS = highest-usage in_top_build nodes that fit within the budget.
        # Overflow in_top_build nodes (snapshot-merge inflation from patch changes)
        # drop into the Jenks pool and get classified by usage like any non-top-build node.
        def assign_tree_tiers(node_rows, budget)
          top_build_nodes = node_rows
            .select { |_, group| group.any? { |r| r["in_top_build"] } }
            .sort_by { |_, group| -primary_talent(group)["usage_pct"].to_f }

          bis_nodes = Set.new
          remaining = budget

          top_build_nodes.each do |node_id, group|
            cost = @talent_info.dig(primary_talent(group)["talent_id"], :max_rank) || 1
            next if cost > remaining

            bis_nodes.add(node_id)
            remaining -= cost
          end

          non_bis_usages = node_rows
            .reject { |node_id, _| bis_nodes.include?(node_id) }
            .map    { |_, group| primary_talent(group)["usage_pct"].to_f }

          # Situational = genuinely competes with BIS nodes.
          # Threshold is half the weakest BIS node's usage: if lowest BIS is at 60%,
          # non-BIS nodes at 42% are real alternatives (same ballpark → situational).
          # If all BIS are at 90%+, anything below 45% is a fringe pick → common.
          # Jenks is skipped here — it creates artificial gaps between near-equal values
          # (e.g. 47% vs 42% get split even though both are genuine situational picks).
          # When no BIS exists (budget=0), fall back to SITUATIONAL_THRESHOLD.
          lowest_bis_pct = bis_nodes.filter_map { |nid|
            node_rows[nid]&.then { |g| primary_talent(g)["usage_pct"].to_f }
          }.min || 0.0
          sit_threshold = bis_nodes.any? ? lowest_bis_pct * 0.5 : SITUATIONAL_THRESHOLD

          sit_nodes = node_rows
            .reject { |node_id, _| bis_nodes.include?(node_id) }
            .select { |_, group| primary_talent(group)["usage_pct"].to_f >= sit_threshold }
            .keys.to_set

          write_tiers(node_rows, bis_nodes, sit_nodes)
        end
        # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

        # PvP talents: pick N from a pool per matchup.
        # Jenks finds the natural break between always-picked (BIS), flex/matchup
        # options (situational), and ignored talents (common) — no hardcoded thresholds.
        def assign_pvp_tiers(group_rows)
          return if group_rows.empty?

          breaks        = jenks_breaks(group_rows.map { |r| r["usage_pct"].to_f }, 3)
          bis_threshold = breaks[1] || BIS_THRESHOLD
          sit_threshold = breaks[0] || SITUATIONAL_THRESHOLD

          group_rows.each do |r|
            r["tier"] = case r["usage_pct"].to_f
            when (bis_threshold..) then "bis"
            when (sit_threshold..) then "situational"
            else "common"
            end
          end
        end

        # ── Fisher-Jenks natural breaks ──────────────────────────────────
        #
        # Partitions `values` into `k` classes by minimising within-class
        # sum-of-squared deviations (Fisher's exact algorithm, O(n²k)).
        # Returns k-1 ascending break points (first value of each upper class).
        # Returns [] when there are not enough distinct values to form k classes.
        #
        # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        def jenks_breaks(values, k)
          sorted = values.map(&:to_f).sort
          return [] if sorted.size <= k

          ssd         = build_ssd_matrix(sorted)
          min_cost    = Array.new(sorted.size) { Array.new(k + 1, Float::INFINITY) }
          class_start = Array.new(sorted.size) { Array.new(k + 1, 0) }

          sorted.each_index { |i| min_cost[i][1] = ssd[0][i] }

          (2..k).each do |num_classes|
            (num_classes - 1...sorted.size).each do |right|
              (num_classes - 2...right).each do |split|
                cost = min_cost[split][num_classes - 1] + ssd[split + 1][right]
                next unless cost < min_cost[right][num_classes]

                min_cost[right][num_classes]    = cost
                class_start[right][num_classes] = split + 1
              end
            end
          end

          _, breaks = k.downto(2).reduce([ sorted.size - 1, [] ]) do |(i, acc), c|
            start = class_start[i][c]
            [ start - 1, acc << sorted[start] ]
          end
          breaks.reverse
        end
        # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

        # rubocop:disable Metrics/AbcSize
        def build_ssd_matrix(sorted)
          n = sorted.size
          Array.new(n) { Array.new(n, 0.0) }.tap do |ssd|
            sorted.each_with_index do |val, i|
              sum    = val
              sum_sq = val**2
              (i + 1...n).each do |j|
                sum    += sorted[j]
                sum_sq += sorted[j]**2
                ssd[i][j] = sum_sq - sum**2 / (j - i + 1).to_f
              end
            end
          end
        end
        # rubocop:enable Metrics/AbcSize

        # Write final tiers to rows. Choice node alternatives demoted one level.
        def write_tiers(node_rows, bis_nodes, sit_nodes)
          node_rows.each do |node_id, node_group|
            tier = case node_id
            when bis_nodes then "bis"
            when sit_nodes then "situational"
            else "common"
            end
            assign_tier_to_node(node_group, tier)
          end
        end

        # For a single node: primary gets the tier, choice alternatives drop one level.
        # Contested BIS choice (gap <= 30 pts): node is required but neither talent is
        # "the" pick — both become situational so players know to choose by matchup.
        # Multi-rank nodes (same talent, multiple ranks) all get the same tier.
        # rubocop:disable Metrics/AbcSize
        def assign_tier_to_node(node_group, tier)
          return node_group.each { |r| r["tier"] = tier } unless choice_node?(node_group) && tier != "common"

          primary     = primary_talent(node_group)
          primary_pct = primary["usage_pct"].to_f
          alts        = node_group.reject { |r| r.equal?(primary) }
          contested   = alts.any? { |r| primary_pct - r["usage_pct"].to_f <= 30.0 }

          # Contested BIS: node required but pick is matchup-dependent — demote all to situational.
          return node_group.each { |r| r["tier"] = "situational" } if tier == "bis" && contested

          primary["tier"] = tier
          alts.each do |r|
            r["tier"] = if contested || (tier == "bis" && r["usage_pct"].to_f >= COMMON_THRESHOLD)
              "situational"
            else
              "common"
            end
          end
        end
        # rubocop:enable Metrics/AbcSize

        # A choice node has multiple talents with different blizzard_ids (real alternatives).
        # Multi-rank nodes have multiple rows but are the same talent at different ranks.
        def choice_node?(node_group)
          return false if node_group.size <= 1

          node_group.map { |r| @talent_info[r["talent_id"]]&.[](:node_id) }.uniq.size == 1 &&
            node_group.map { |r| r["talent_id"] }.uniq.size > 1 &&
            unique_talent_names(node_group) > 1
        end

        def unique_talent_names(node_group)
          @talent_names ||= Translation
            .where(translatable_type: "Talent", key: "name", locale: "en_US")
            .pluck(:translatable_id, :value)
            .to_h
          node_group.map { |r| @talent_names[r["talent_id"]] }.compact.uniq.size
        end

        # ── Hero tree logic ─────────────────────────────────────────────
        #
        # Hero talents have 2 sub-trees (connected components). Players pick one.
        # Selected sub-tree (higher avg usage): all BiS, choice alts → situational.
        # Off-tree: all situational if avg >= 30%, otherwise common.

        def assign_hero_tiers(node_rows)
          sub_trees = find_connected_components(node_rows.keys)

          ranked = sub_trees
            .map { |nodes| { nodes: nodes, avg: avg_usage(nodes, node_rows) } }
            .sort_by { |t| -t[:avg] }

          ranked.each_with_index do |tree, idx|
            if idx == 0
              assign_selected_hero_tree(tree[:nodes], node_rows)
            else
              assign_off_hero_tree(tree[:nodes], tree[:avg], node_rows)
            end
          end
        end

        def assign_selected_hero_tree(node_ids, node_rows)
          node_ids.each do |node_id|
            node_group = node_rows[node_id]
            next unless node_group

            assign_tier_to_node(node_group, "bis")
          end
        end

        def assign_off_hero_tree(node_ids, avg, node_rows)
          tier = avg >= HERO_OFF_TREE_THRESHOLD ? "situational" : "common"
          node_ids.each do |node_id|
            node_group = node_rows[node_id]
            next unless node_group

            node_group.each { |r| r["tier"] = tier }
          end
        end

        def avg_usage(node_ids, node_rows)
          pcts = node_ids.flat_map { |nid| (node_rows[nid] || []).map { |r| r["usage_pct"].to_f } }
          pcts.any? ? pcts.sum / pcts.size : 0.0
        end

        # Split node_ids into connected components via undirected prereq edges.
        def find_connected_components(node_ids)
          node_set = node_ids.to_set
          adj = build_undirected_adjacency(node_set)

          visited    = Set.new
          components = []

          node_ids.each do |n|
            next if visited.include?(n)

            component = bfs_component(n, adj, visited)
            components << component
          end

          components
        end

        def build_undirected_adjacency(node_set)
          adj = Hash.new { |h, k| h[k] = Set.new }
          @prereqs.each do |nid, prereq_ids|
            next unless node_set.include?(nid)

            prereq_ids.each do |pid|
              next unless node_set.include?(pid)

              adj[nid].add(pid)
              adj[pid].add(nid)
            end
          end
          adj
        end

        def bfs_component(start, adj, visited)
          component = Set.new
          stack     = [ start ]
          while stack.any?
            cur = stack.pop
            next if component.include?(cur)

            component.add(cur)
            visited.add(cur)
            adj[cur].each { |nb| stack << nb unless component.include?(nb) }
          end
          component
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
