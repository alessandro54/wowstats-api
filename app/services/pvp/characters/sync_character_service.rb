module Pvp
  module Characters
    # rubocop:disable Metrics/ClassLength
    class SyncCharacterService < BaseService
      # Carries the result of a single ETag-aware Blizzard API fetch.
      #   json    — parsed response body (nil on 304)
      #   last_modified — Last-Modified header to store on the character
      #   changed — true = 200 (new data), false = 304 (unchanged)
      FetchResult = Struct.new(:json, :last_modified, :changed, keyword_init: true) do
        def changed?   = changed
        def unchanged? = !changed
      end

      def initialize(character:, locale: "en_US", entries: nil,
                     eq_fallback_source: nil, spec_fallback_source: nil)
        @character            = character
        @locale               = locale
        @preloaded_entries    = entries
        @eq_fallback_source   = eq_fallback_source
        @spec_fallback_source = spec_fallback_source
      end

      # rubocop:disable Metrics/AbcSize
      def call
        return success(nil, context: { status: :not_found }) unless character
        return success(nil, context: { status: :skipped_private }) if character.is_private

        entries = ApplicationRecord.connection_pool.with_connection { latest_entries_per_bracket }
        return success(nil, context: { status: :no_entries }) if entries.empty?

        # If no processed entries exist, the 304 fallback has no source to
        # copy from. Clear Last-Modified so Blizzard returns 200 (full data)
        # instead of 304, ensuring entries get all attrs on first sync or
        # after a data reset.
        ApplicationRecord.connection_pool.with_connection { clear_stale_last_modified! }

        # Always hit Blizzard — the API returns 304 when data is unchanged
        # (cheap), so we don't need a client-side TTL guard. On 304 the
        # existing processed data is propagated to new entries; on 200 fresh
        # data is written.
        eq_fetch, spec_fetch = fetch_remote_data

        if @profile_not_found
          ApplicationRecord.connection_pool.with_connection do
            # rubocop:disable Rails/SkipsModelValidations
            character.update_columns(unavailable_until: UNAVAILABILITY_COOLDOWN.from_now)
            # rubocop:enable Rails/SkipsModelValidations
            # Purge stale data so deleted/transferred characters don't pollute meta aggregations
            character.character_talents.delete_all
            character.character_items.delete_all
          end
        end

        return success(nil, context: { status: :equipment_unavailable }) if eq_fetch.nil?
        return success(nil, context: { status: :talents_unavailable })   if spec_fetch.nil?

        ApplicationRecord.connection_pool.with_connection { process_inline(entries, eq_fetch, spec_fetch) }
        success(entries, context: { status: :synced })
      rescue => e
        failure(e)
      end
      # rubocop:enable Metrics/AbcSize

      private

        attr_reader :character, :locale, :preloaded_entries

        # ------------------------------------------------------------------
        # Inline processing (fresh fetch or 304)
        # ------------------------------------------------------------------

        EQUIPMENT_ENTRY_ATTRS = %i[
          equipment_processed_at item_level tier_set_id tier_set_name
          tier_set_pieces tier_4p_active
        ].freeze

        # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
        def process_inline(entries, eq_fetch, spec_fetch)
          entry_attrs         = {}
          char_attrs          = {}
          active_spec_id      = nil
          per_spec_hero_trees = {}
          sync_done           = false
          eq_changed          = eq_fetch.changed?

          # rubocop:disable Metrics/BlockLength
          with_deadlock_retry do
            ApplicationRecord.transaction do
              # --- Specialization FIRST (to get active spec_id) ---
              if spec_fetch.changed?
                spec_result = Pvp::Entries::ProcessSpecializationService.call(
                  character:          character,
                  raw_specialization: spec_fetch.json,
                  locale:             locale
                )

                unless spec_result.success?
                  log_service_failure("Specialization", character, spec_result.error)
                  raise ActiveRecord::Rollback
                end

                entry_attrs.merge!(spec_result.context[:entry_attrs]) if spec_result.context[:entry_attrs]
                char_attrs.merge!(spec_result.context[:char_attrs])   if spec_result.context[:char_attrs]
                char_attrs[:talents_last_modified] = spec_fetch.last_modified if spec_fetch.last_modified.present?
                active_spec_id      = spec_result.context[:entry_attrs]&.dig(:spec_id)
                per_spec_hero_trees = spec_result.context[:per_spec_hero_trees] || {}
              else
                # 304: talents unchanged — propagate attrs from latest processed entry
                entry_attrs.merge!(spec_entry_attrs_from_latest)
                active_spec_id = entry_attrs[:spec_id]
              end

              # --- Equipment (with active_spec_id) ---
              if eq_changed
                if active_spec_id
                  eq_result = Pvp::Entries::ProcessEquipmentService.call(
                    character:     character,
                    raw_equipment: eq_fetch.json,
                    spec_id:       active_spec_id,
                    locale:        locale
                  )

                  unless eq_result.success?
                    log_service_failure("Equipment", character, eq_result.error)
                    raise ActiveRecord::Rollback
                  end

                  entry_attrs.merge!(eq_result.context[:entry_attrs]) if eq_result.context[:entry_attrs]
                end
                char_attrs[:equipment_last_modified] = eq_fetch.last_modified if eq_fetch.last_modified.present?
              else
                # 304: equipment unchanged — propagate attrs from latest processed entry
                entry_attrs.merge!(equipment_entry_attrs_from_latest)
              end

              # Compute stat totals from character_items whenever gear changed or not yet computed.
              if eq_changed || character.stat_pcts.blank?
                spec_id = active_spec_id || entry_attrs[:spec_id]
                if spec_id
                  totals_result = ComputeStatTotalsService.call(character: character, spec_id: spec_id)
                  if totals_result.success? && totals_result.payload.present?
                    char_attrs[:stat_pcts] = totals_result.payload
                  end
                end
              end

              # --- Spec-aware entry updates ---
              update_entries_with_spec_awareness(entries, entry_attrs, active_spec_id, per_spec_hero_trees)

              char_attrs[:last_equipment_snapshot_at] = Time.current
              char_attrs[:unavailable_until]          = nil

              # rubocop:disable Rails/SkipsModelValidations
              character.update_columns(char_attrs)
              # rubocop:enable Rails/SkipsModelValidations

              sync_done = true
            end
          end # with_deadlock_retry
          # rubocop:enable Metrics/BlockLength

          # Extra locale translations make HTTP API calls — must run OUTSIDE the DB transaction
          sync_extra_locale_translations if eq_changed && sync_done
        end
        # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

        # Entries whose spec matches the active spec get full attrs (equipment + talents).
        # Entries with a different spec (e.g., shuffle bracket) get talent attrs only —
        # equipment_processed_at is NOT set because the gear doesn't match.
        # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        def update_entries_with_spec_awareness(entries, entry_attrs, active_spec_id, per_spec_hero_trees)
          return if entry_attrs.empty?

          matching_ids     = []
          non_matching_ids = []

          entries.each do |e|
            if e.spec_id.nil? || e.spec_id == active_spec_id
              matching_ids << e.id
            else
              non_matching_ids << e.id
            end
          end

          now = Time.current

          # rubocop:disable Rails/SkipsModelValidations
          if matching_ids.any?
            PvpLeaderboardEntry.where(id: matching_ids).update_all(
              entry_attrs.merge(updated_at: now)
            )
          end

          return unless non_matching_ids.any?

          talent_only_attrs = entry_attrs.except(*EQUIPMENT_ENTRY_ATTRS)
          return unless talent_only_attrs.any?

          # Apply per-spec hero tree info if available
          entries.select { |e| non_matching_ids.include?(e.id) }.group_by(&:spec_id).each do |sid, group|
            hero_info = per_spec_hero_trees[sid] || {}
            attrs = talent_only_attrs.merge(hero_info).merge(updated_at: now)
            # Don't overwrite the bracket-derived spec_id
            attrs.delete(:spec_id)
            PvpLeaderboardEntry.where(id: group.map(&:id)).update_all(attrs)
          end


          # rubocop:enable Rails/SkipsModelValidations
        end
        # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

        # ------------------------------------------------------------------
        # 304 fallback: copy entry-level attrs from latest processed entry
        # ------------------------------------------------------------------

        def equipment_entry_attrs_from_latest
          source = @eq_fallback_source || PvpLeaderboardEntry
            .where(character_id: character.id)
            .where.not(equipment_processed_at: nil)
            .order(equipment_processed_at: :desc)
            .first
          return {} unless source

          {
            item_level:             source.item_level,
            tier_set_id:            source.tier_set_id,
            tier_set_name:          source.tier_set_name,
            tier_set_pieces:        source.tier_set_pieces,
            tier_4p_active:         source.tier_4p_active,
            equipment_processed_at: source.equipment_processed_at
          }
        end

        def spec_entry_attrs_from_latest
          source = @spec_fallback_source || PvpLeaderboardEntry
            .where(character_id: character.id)
            .where.not(specialization_processed_at: nil)
            .order(specialization_processed_at: :desc)
            .first
          return {} unless source

          {
            spec_id:                     source.spec_id,
            hero_talent_tree_id:         source.hero_talent_tree_id,
            hero_talent_tree_name:       source.hero_talent_tree_name,
            specialization_processed_at: source.specialization_processed_at
          }
        end

        # ------------------------------------------------------------------
        # Blizzard API fetch (two parallel threads)
        # ------------------------------------------------------------------

        def fetch_remote_data
          eq_fetch   = nil
          spec_fetch = nil

          threads = [
            Thread.new { eq_fetch   = safe_fetch { fetch_equipment_with_last_modified } },
            Thread.new { spec_fetch = safe_fetch { fetch_talents_with_last_modified } }
          ]
          threads.each(&:join)

          [ eq_fetch, spec_fetch ]
        end

        def fetch_equipment_with_last_modified
          json, last_modified_str, changed = Blizzard::Api::Profile::CharacterEquipmentSummary.fetch_with_last_modified(
            region:        character.region,
            realm:         character.realm,
            name:          character.name,
            locale:        region_locale,
            last_modified: character.equipment_last_modified&.httpdate
          )
          FetchResult.new(json: json, last_modified: parse_last_modified(last_modified_str), changed: changed)
        end

        def fetch_talents_with_last_modified
          json, last_modified_str, changed = Blizzard::Api::Profile::CharacterSpecializationSummary.fetch_with_last_modified(
            region:        character.region,
            realm:         character.realm,
            name:          character.name,
            locale:        region_locale,
            last_modified: character.talents_last_modified&.httpdate
          )
          FetchResult.new(json: json, last_modified: parse_last_modified(last_modified_str), changed: changed)
        end

        def parse_last_modified(value)
          return nil if value.blank?

          Time.parse(value).utc
        end

        # Fetch equipment in each extra locale configured for this region and
        # upsert translations. Called only when primary equipment changed (200),
        # so 304 cycles never trigger unnecessary API calls.
        def sync_extra_locale_translations
          extra = Pvp::RegionConfig::REGION_EXTRA_LOCALES[character.region] || []
          return if extra.empty?

          threads = extra.map do |extra_locale|
            Thread.new do
              json = Blizzard::Api::Profile::CharacterEquipmentSummary.fetch(
                region: character.region,
                realm:  character.realm,
                name:   character.name,
                locale: extra_locale
              )
              Blizzard::Data::Items::UpsertFromRawEquipmentService.call(raw_equipment: json, locale: extra_locale)
            rescue StandardError => e
              logger.warn("[SyncCharacterService] Extra locale #{extra_locale} fetch failed: #{e.message}")
            end
          end
          threads.each(&:join)
        end

        # Character profile endpoints don't carry translation-sensitive text —
        # use the region's default locale so the API call is always valid
        # regardless of what translation locale was requested.
        def region_locale
          Blizzard::Client.default_locale_for(character.region)
        end

        def safe_fetch
          yield
        rescue Blizzard::Client::Error => e
          handle_blizzard_error(e)
          nil
        end

        UNAVAILABILITY_COOLDOWN = 2.weeks

        def handle_blizzard_error(error)
          if error.is_a?(Blizzard::Client::NotFoundError)
            logger.warn(
              "[SyncCharacterService] 404 for character #{character.id} — " \
              "profile deleted or transferred, cooling down for 2 weeks"
            )
            @profile_not_found = true
          elsif error.is_a?(Blizzard::Client::RateLimitedError)
            logger.warn("[SyncCharacterService] Rate limited (429), skipping character")
          else
            logger.error("[SyncCharacterService] Error fetching profile: #{error.message}")
          end
        end

        # When no processed entries exist for a character (e.g. first sync
        # or after manual data deletion), clear Last-Modified timestamps so
        # Blizzard returns 200 instead of 304.  Without this, a 304 fallback
        # would find no source entry and leave new entries unprocessed.
        # rubocop:disable Metrics/AbcSize
        def clear_stale_last_modified!
          has_eq_last_mod   = character.equipment_last_modified.present? && !@eq_fallback_source
          has_spec_last_mod = character.talents_last_modified.present? && !@spec_fallback_source

          return unless has_eq_last_mod || has_spec_last_mod

          counts = PvpLeaderboardEntry.where(character_id: character.id)
            .pick(
              Arel.sql("COUNT(*) FILTER (WHERE equipment_processed_at IS NOT NULL)"),
              Arel.sql("COUNT(*) FILTER (WHERE specialization_processed_at IS NOT NULL)")
            )

          eq_count, spec_count = counts || [ 0, 0 ]

          attrs = {}
          attrs[:equipment_last_modified] = nil if has_eq_last_mod && eq_count.zero?
          attrs[:talents_last_modified]   = nil if has_spec_last_mod && spec_count.zero?

          return unless attrs.any?

          # rubocop:disable Rails/SkipsModelValidations
          character.update_columns(attrs)
          # rubocop:enable Rails/SkipsModelValidations
          logger.info(
            "[SyncCharacterService] Cleared stale Last-Modified for character #{character.id} " \
            "(#{attrs.keys.join(', ')}) — no processed entries to fall back on"
          )
        end
        # rubocop:enable Metrics/AbcSize

        def latest_entries_per_bracket
          return preloaded_entries unless preloaded_entries.nil?

          PvpLeaderboardEntry.where(character_id: character.id)
        end

        def log_service_failure(stage, character, error)
          label = "[SyncCharacterService] #{stage} processing failed " \
                  "for character #{character.id} (#{character.display_name})"

          if error.is_a?(Exception)
            backtrace = error.backtrace&.first(8)&.join("\n  ")
            logger.error("#{label}: #{error.class}: #{error.message}\n  #{backtrace}")
          else
            logger.error("#{label}: #{error}")
          end
        end

        def logger
          Rails.logger
        end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
