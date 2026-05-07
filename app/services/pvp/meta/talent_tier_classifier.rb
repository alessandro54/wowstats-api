module Pvp
  module Meta
    # rubocop:disable Metrics/ClassLength
    class TalentTierClassifier
      # Fallback thresholds used when Jenks cannot find natural breaks
      # (fewer than k+1 distinct usage values in the group).
      BIS_THRESHOLD         = 75.0
      SITUATIONAL_THRESHOLD = 50.0
      COMMON_THRESHOLD      = 35.0

      TREE_BUDGETS = { "class" => 34, "spec" => 34, "hero" => 10 }.freeze
      HERO_OFF_TREE_THRESHOLD = 30.0

      def initialize(rows:, prereqs:, talent_info:, talent_names: nil)
        @rows         = rows
        @prereqs      = prereqs
        @talent_info  = talent_info
        @talent_names = talent_names
      end

      def call
        return @rows if @rows.empty?

        groups = @rows.group_by { |r| [ r["bracket"], r["spec_id"], r["talent_type"] ] }

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

        @rows
      end

      private

        # Groups rows by node_id. Talents on the same node are choice alternatives.
        def build_node_rows(group_rows)
          node_rows = Hash.new { |h, k| h[k] = [] }
          group_rows.each do |r|
            info = @talent_info[r["talent_id"]]
            next unless info&.[](:node_id)

            node_rows[info[:node_id]] << r
          end
          node_rows
        end

        # Highest-usage talent on a node (the "pick" for choice nodes).
        def primary_talent(node_group)
          node_group.max_by { |r| r["usage_pct"].to_f }
        end

        # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        # BiS = highest-usage in_top_build nodes that fit within the budget.
        # Overflow nodes drop into the situational pool.
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

          # Situational threshold = half the weakest BIS node's usage, so a
          # 60% BIS keeps 42% picks alive but a 90% BIS prunes them. Jenks
          # is skipped — splits near-equal values arbitrarily. Falls back to
          # SITUATIONAL_THRESHOLD when no BIS exists (budget=0).
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

        # PvP: Jenks splits the pool into BIS / situational / common with no
        # hardcoded thresholds. Falls back to constants on small samples.
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

        # Fisher–Jenks natural breaks. O(n²k). Returns k-1 ascending break
        # points or [] when there aren't enough distinct values.
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

        # Primary gets the tier, choice alternatives drop one level.
        # Contested BIS choice (gap ≤ 30 pts): both demoted to situational —
        # node is required but pick is matchup-dependent.
        # rubocop:disable Metrics/AbcSize
        def assign_tier_to_node(node_group, tier)
          return node_group.each { |r| r["tier"] = tier } unless choice_node?(node_group) && tier != "common"

          primary     = primary_talent(node_group)
          primary_pct = primary["usage_pct"].to_f
          alts        = node_group.reject { |r| r.equal?(primary) }
          contested   = alts.any? { |r| primary_pct - r["usage_pct"].to_f <= 30.0 }

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

        # Choice = multiple talents on the same node with different names.
        # Multi-rank = same talent at different ranks (not a choice).
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

        # Hero tree = 2 sub-trees (connected components). Selected (higher
        # avg usage): all BiS. Off-tree: situational if avg ≥ 30%, else common.
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
    end
    # rubocop:enable Metrics/ClassLength
  end
end
