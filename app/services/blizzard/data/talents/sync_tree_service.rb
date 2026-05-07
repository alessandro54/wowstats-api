module Blizzard
  module Data
    module Talents
      # Fetches talent tree layout from Blizzard's static Game Data API and persists:
      #   - node_id, display_row, display_col, max_rank, spell_id, talent_type on each Talent
      #   - prerequisite edges in TalentPrerequisite
      #   - spec assignments in TalentSpecAssignment
      #
      # Media (icon_url, descriptions) is fetched asynchronously by SyncTalentMediaJob.
      #
      # Run once after a major patch or on-demand:
      #   SyncTalentTreesJob.perform_later
      class SyncTreeService < BaseService # rubocop:disable Metrics/ClassLength
        TALENT_TYPE_PRIORITY = { "class" => 0, "spec" => 1, "hero" => 2 }.freeze

        # Required top-level keys in a per-spec tree response. Empty arrays are OK
        # (logged + skipped); a missing key signals an API contract change and aborts.
        REQUIRED_TREE_KEYS = %w[class_talent_nodes spec_talent_nodes hero_talent_trees].freeze

        # Per-talent_type ratio at which the new sync's count is considered a
        # regression vs the last successful run. 0.5 = abort if new is < 50% of old.
        REGRESSION_RATIO_THRESHOLD = 0.5

        # Per-talent_type minimum absolute count below which the result is suspect
        # regardless of ratio (e.g. previous run had 5 hero talents, ratio comparison
        # is meaningless — but 0 is still wrong). Hand-tuned, conservative.
        REGRESSION_FLOOR = { "class" => 100, "spec" => 100, "hero" => 100 }.freeze

        def initialize(region: "us", locale: "en_US", force: false)
          @region = region
          @force  = force
          @client = Blizzard::Client.new(region: region, locale: locale)
        end

        # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        def call
          @run = TalentSyncRun.create!(
            region: @region, locale: @client.locale, force: force?,
            status: "running", started_at: Time.current
          )

          spec_entries     = Array(fetch_index["spec_talent_trees"])
          talent_attrs     = {}
          name_map         = {} # blizzard_id => name (from tree response, locale-aware)
          edges            = Set.new
          # spec_id => { talent_type => Set<blizzard_id> }
          spec_assignments = Hash.new { |h, k| h[k] = Hash.new { |hh, kk| hh[kk] = Set.new } }
          failed_specs     = []

          spec_entries.each do |entry|
            tree_id, spec_id = parse_ids(entry.dig("key", "href"))
            next unless tree_id && spec_id

            tree = fetch_tree(tree_id, spec_id)

            unless validate_tree_response!(tree, spec_id)
              failed_specs << spec_id
              next
            end

            process_tree(tree, talent_attrs, edges, spec_assignments[spec_id], name_map, spec_id: spec_id)
          rescue Blizzard::Client::Error => e
            failed_specs << spec_id
            log_warn("Skipping tree #{tree_id}/#{spec_id}: #{e.message}")
          end

          counts     = build_counts(talent_attrs, edges)
          regression = detect_regression(counts)

          return abort_for_regression!(regression, counts, failed_specs) if regression[:detected] && !force?

          if force?
            apply_positions(talent_attrs)
            apply_prerequisites(edges) if failed_specs.empty?
          else
            apply_positions_for_incomplete(talent_attrs)
            apply_prerequisites(edges) if TalentPrerequisite.none? && failed_specs.empty?
          end

          apply_talent_types(talent_attrs)
          apply_spec_assignments(spec_assignments, skip_specs: failed_specs)
          save_names_from_tree(name_map)

          # Media (icons, descriptions) only changes on patch day — only fetch on force sync.
          SyncTalentMediaJob.perform_later(region: @region, locale: @client.locale) if force?

          finalize_run!("success", counts: counts, failed_specs: failed_specs, regression: regression)
          success(nil, context: { talents: talent_attrs.size, edges: edges.size, run_id: @run.id })
        rescue Blizzard::Client::Error, ActiveRecord::ActiveRecordError => e
          finalize_run!("failure", error: e.message)
          failure(e)
        end
        # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

        private

          attr_reader :region, :client

          def force? = @force

          # ── Schema validation (#3) ──────────────────────────────────────
          #
          # A missing top-level key signals a Blizzard API contract change.
          # Empty arrays are OK (logged in process_tree); a missing key skips
          # the spec rather than silently treating it as zero data.
          def validate_tree_response!(tree, spec_id)
            return false unless tree.is_a?(Hash)

            missing = REQUIRED_TREE_KEYS - tree.keys
            return true if missing.empty?

            log_warn("Tree response for spec #{spec_id} missing keys: #{missing.inspect} — skipping spec")
            Sentry.capture_message(
              "SyncTreeService schema regression",
              level: :warning,
              extra: { spec_id: spec_id, missing_keys: missing, present_keys: tree.keys }
            )
            false
          end

          # ── Run-level counts (#7) ───────────────────────────────────────
          def build_counts(talent_attrs, edges)
            counts = Hash.new(0)
            talent_attrs.each_value { |attrs| counts[attrs[:talent_type].to_s] += 1 }
            counts["edges"]   = edges.size
            counts["talents"] = talent_attrs.size
            counts.transform_keys(&:to_s)
          end

          # ── Regression detection (#2) ───────────────────────────────────
          #
          # Compares per-talent_type counts against the last successful run.
          # Either a hard floor breach (e.g. hero=0) or a sharp drop versus
          # the prior run flags the result as a regression. force: true skips
          # this guard for legitimate post-patch resyncs that genuinely shrink.
          # rubocop:disable Metrics/AbcSize
          def detect_regression(counts)
            baseline = TalentSyncRun.last_success_for(@region)&.counts.to_h
            details  = []

            %w[class spec hero].each do |type|
              new_n  = counts[type].to_i
              prev_n = baseline[type].to_i
              floor  = REGRESSION_FLOOR.fetch(type, 0)

              if new_n < floor
                details << { type: type, reason: "below_floor", new: new_n, floor: floor, prev: prev_n }
                next
              end

              next if prev_n.zero? # no baseline → don't flag

              ratio = new_n.to_f / prev_n
              if ratio < REGRESSION_RATIO_THRESHOLD
                details << { type: type, reason: "ratio_drop", new: new_n, prev: prev_n, ratio: ratio.round(2) }
              end
            end

            { detected: details.any?, details: details, baseline_run_at: baseline.present? ? "present" : "none" }
          end
          # rubocop:enable Metrics/AbcSize

          def abort_for_regression!(regression, counts, failed_specs)
            log_error("Aborting sync — count regression: #{regression[:details].inspect}")
            Sentry.capture_message(
              "SyncTreeService aborted for count regression",
              level: :error,
              extra: { region: @region, counts: counts, regression: regression }
            )
            finalize_run!("aborted_regression",
              counts: counts, failed_specs: failed_specs, regression: regression,
              error: "count regression vs prior run; pass force: true to override"
            )
            failure(StandardError.new("count regression detected"),
              context: { region: @region, regression: regression }, captured: true
            )
          end

          # ── Run persistence (#7) ────────────────────────────────────────
          def finalize_run!(status, counts: nil, failed_specs: nil, regression: nil, error: nil)
            return unless @run

            attrs = { status: status, completed_at: Time.current }
            attrs[:counts]        = counts        if counts
            attrs[:failed_specs]  = failed_specs  if failed_specs
            attrs[:regression]    = regression    if regression
            attrs[:error_message] = error         if error
            attrs[:tsa_counts]    = current_tsa_counts if status == "success"
            @run.update!(attrs)
          end

          def current_tsa_counts
            TalentSpecAssignment.joins(:talent).group("talents.talent_type").count
          rescue StandardError
            {}
          end

          def fetch_index
            client.get("/data/wow/talent-tree/index", namespace: client.static_namespace)
          end

          def fetch_tree(tree_id, spec_id)
            client.get(
              "/data/wow/talent-tree/#{tree_id}/playable-specialization/#{spec_id}",
              namespace: client.static_namespace
            )
          end

          def parse_ids(href)
            return [ nil, nil ] unless href

            m = href.match(%r{/talent-tree/(\d+)/playable-specialization/(\d+)})
            return [ nil, nil ] unless m

            [ m[1].to_i, m[2].to_i ]
          end

          # rubocop:disable Metrics/AbcSize
          def process_tree(tree, talent_attrs, edges, assignments, name_map, spec_id: nil)
            process_nodes(Array(tree["class_talent_nodes"]), "class", talent_attrs, edges, assignments, name_map)
            process_nodes(Array(tree["spec_talent_nodes"]),  "spec",  talent_attrs, edges, assignments, name_map)
            hero_trees = Array(tree["hero_talent_trees"])
            if hero_trees.empty?
              log_warn("Tree response missing hero_talent_trees for spec #{spec_id || '?'} — " \
                       "existing hero TSAs preserved")
            end
            hero_trees.each do |hero|
              # Blizzard's API renamed "nodes" → "hero_talent_nodes" inside each hero tree.
              # Fall back to the old key for backwards compatibility.
              hero_nodes = Array(hero["hero_talent_nodes"]).presence || Array(hero["nodes"])
              if hero_nodes.empty?
                # Skip process_nodes entirely so the "hero" bucket never gets registered
                # for this spec. Otherwise apply_spec_assignments would treat hero as a
                # seen talent_type and delete every existing hero TSA.
                log_warn("Hero tree #{hero['id']} (#{hero['name']}) for spec #{spec_id || '?'} has no nodes")
                next
              end
              process_nodes(hero_nodes, "hero", talent_attrs, edges, assignments, name_map)
            end
          end
          # rubocop:enable Metrics/AbcSize

          # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
          def process_nodes(nodes, talent_type, talent_attrs, edges, assignments, name_map)
            # Backwards-compat: accept either Hash<type, Set> or a plain Set (used by legacy specs).
            ids_bucket = assignments.is_a?(Hash) ? assignments[talent_type] : assignments

            nodes.each do |node|
              node_id     = node["id"]
              display_row = node["display_row"]
              display_col = node["display_col"]
              max_rank    = [ Array(node["ranks"]).size, 1 ].max

              talents_from_node(node).each do |blizzard_id, spell_id, name|
                existing_priority = TALENT_TYPE_PRIORITY[talent_attrs.dig(blizzard_id, :talent_type).to_s] || -1
                new_priority      = TALENT_TYPE_PRIORITY[talent_type] || 0

                # Hero always wins — don't overwrite a higher-priority type (e.g. Halo appears
                # in class_talent_nodes for some specs but hero_talent_trees for others).
                if new_priority >= existing_priority
                  talent_attrs[blizzard_id] = {
                    node_id:     node_id,
                    display_row: display_row,
                    display_col: display_col,
                    max_rank:    max_rank,
                    spell_id:    spell_id,
                    talent_type: talent_type
                  }
                end

                name_map[blizzard_id] = name if name.present?
                ids_bucket.add(blizzard_id)
              end

              Array(node["locked_by"]).each do |prereq|
                prereq_id = prereq.is_a?(Hash) ? prereq["id"] : prereq
                edges << [ node_id, prereq_id ] if prereq_id
              end
            end
          end
          # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

          # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
          # Returns [[blizzard_id, spell_id, name], ...] for all talents in the node.
          # Handles regular nodes (ranks[].tooltip) and choice nodes (ranks[].choice_of_tooltips).
          def talents_from_node(node)
            Array(node["ranks"]).flat_map do |rank|
              if rank["tooltip"]
                talent   = rank.dig("tooltip", "talent")
                spell_id = rank.dig("tooltip", "spell_tooltip", "spell", "id")
                talent ? [ [ talent["id"], spell_id, talent["name"] ] ] : []
              elsif rank["choice_of_tooltips"]
                rank["choice_of_tooltips"].filter_map do |c|
                  talent   = c["talent"]
                  spell_id = c.dig("spell_tooltip", "spell", "id")
                  [ talent["id"], spell_id, talent["name"] ] if talent
                end
              else
                []
              end
            end.uniq { |blizzard_id, _| blizzard_id }.compact
          end
          # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

          def apply_positions_for_incomplete(talent_attrs)
            return if talent_attrs.empty?

            incomplete_ids = Talent
              .where(blizzard_id: talent_attrs.keys)
              .where("node_id IS NULL OR spell_id IS NULL")
              .pluck(:blizzard_id)

            return if incomplete_ids.empty?

            apply_positions(talent_attrs.slice(*incomplete_ids))
          end

          def apply_talent_types(talent_attrs)
            return if talent_attrs.empty?

            conn   = ApplicationRecord.connection
            id_map = Talent
              .where(blizzard_id: talent_attrs.keys)
              .pluck(:id, :blizzard_id)
              .to_h { |(id, blz)| [ blz, id ] }

            return if id_map.empty?

            values = id_map.map do |blizzard_id, talent_id|
              type = conn.quote(talent_attrs[blizzard_id][:talent_type])
              "(#{talent_id.to_i}, #{type})"
            end.join(", ")

            # Never downgrade hero — hero classification comes from character profile data
            # (raw_specialization["hero_talents"]), which is more authoritative than the
            # static tree API (which keeps gateway talents like Halo in class_talent_nodes).
            conn.execute(<<~SQL)
              UPDATE talents
              SET talent_type = v.talent_type, updated_at = NOW()
              FROM (VALUES #{values}) AS v(id, talent_type)
              WHERE talents.id = v.id
                AND talents.talent_type IS DISTINCT FROM v.talent_type
                AND talents.talent_type != 'hero'
            SQL
          end

          # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
          def apply_positions(talent_attrs)
            return if talent_attrs.empty?

            id_map = Talent
              .where(blizzard_id: talent_attrs.keys)
              .pluck(:id, :blizzard_id)
              .to_h { |(id, blz)| [ blz, id ] }

            return if id_map.empty?

            # Single bulk UPDATE via VALUES — upsert_all can't be used because the
            # INSERT leg would violate blizzard_id NOT NULL.
            conn = ApplicationRecord.connection
            values = id_map.map do |blizzard_id, talent_id|
              a           = talent_attrs[blizzard_id]
              spell_id    = a[:spell_id] ? a[:spell_id].to_i.to_s : "NULL"
              talent_type = conn.quote(a[:talent_type])
              "(#{talent_id.to_i}, #{a[:node_id].to_i}, #{a[:display_row].to_i}, " \
                "#{a[:display_col].to_i}, #{a[:max_rank].to_i}, #{spell_id}, #{talent_type})"
            end.join(", ")

            conn.execute(<<~SQL)
              UPDATE talents
              SET node_id = v.node_id, display_row = v.display_row,
                  display_col = v.display_col, max_rank = v.max_rank,
                  spell_id = v.spell_id, talent_type = v.talent_type,
                  updated_at = NOW()
              FROM (VALUES #{values})
                AS v(id, node_id, display_row, display_col, max_rank, spell_id, talent_type)
              WHERE talents.id = v.id
            SQL
          end
          # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

          def apply_prerequisites(edges)
            return if edges.empty?

            now  = Time.current
            rows = edges
              .map { |(n, p)| { node_id: n, prerequisite_node_id: p, created_at: now, updated_at: now } }
              .uniq { |r| [ r[:node_id], r[:prerequisite_node_id] ] }

            ApplicationRecord.transaction do
              TalentPrerequisite.delete_all
              # rubocop:disable Rails/SkipsModelValidations
              TalentPrerequisite.insert_all!(rows)
              # rubocop:enable Rails/SkipsModelValidations
            end
          end

          # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
          # spec_assignments :: { spec_id => { talent_type => Set<blizzard_id> } }
          def apply_spec_assignments(spec_assignments, skip_specs: [])
            return if spec_assignments.empty?

            all_blizzard_ids = spec_assignments.values.flat_map { |by_type| by_type.values.flat_map(&:to_a) }.uniq
            id_map = Talent
              .where(blizzard_id: all_blizzard_ids)
              .pluck(:blizzard_id, :id)
              .to_h

            now = Time.current

            # rubocop:disable Rails/SkipsModelValidations
            spec_assignments.each do |spec_id, by_type|
              next if skip_specs.include?(spec_id)
              next if by_type.empty?

              seen_types = by_type.keys
              talent_ids = by_type.values.flat_map(&:to_a).uniq.filter_map { |blz_id| id_map[blz_id] }
              next if talent_ids.empty?

              ApplicationRecord.transaction do
                # Only delete TSAs for talent_types present in this sync. If a tree
                # section (e.g. hero_talent_trees) is missing from the API response,
                # existing assignments for that type are preserved instead of wiped.
                TalentSpecAssignment
                  .where(spec_id: spec_id)
                  .joins(:talent)
                  .where(talents: { talent_type: seen_types })
                  .where.not(talent_id: talent_ids)
                  .delete_all

                rows = talent_ids.map { |tid| { talent_id: tid, spec_id: spec_id, created_at: now, updated_at: now } }
                TalentSpecAssignment.insert_all(rows, unique_by: %i[talent_id spec_id])
              end
            end
            # rubocop:enable Rails/SkipsModelValidations
          end
          # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

          def save_names_from_tree(name_map)
            return if name_map.empty?

            Talent.where(blizzard_id: name_map.keys).find_each do |talent|
              name = name_map[talent.blizzard_id]
              talent.set_translation("name", client.locale, name, meta: { source: "blizzard" }) if name.present?
            end
          end
      end
    end
  end
end
