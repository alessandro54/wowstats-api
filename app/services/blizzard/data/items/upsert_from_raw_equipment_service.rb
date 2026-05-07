module Blizzard
  module Data
    module Items
      # rubocop:disable Metrics/ClassLength
      class UpsertFromRawEquipmentService < BaseService
        EXCLUDED_SLOTS = %w[TABARD SHIRT].freeze
        SECONDARY_STATS = %w[HASTE_RATING CRIT_RATING MASTERY_RATING VERSATILITY].freeze
        CACHE_TTL = 1.hour

        def initialize(raw_equipment:, locale: "en_US")
          @items  = valid_items(raw_equipment)
          @locale = locale
        end

        # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        def call
          return { "equipped_items" => {} } if items.empty?

          # Deduplicate by blizzard_id before upsert_all: a character can equip the
          # same item in two slots (e.g. identical rings). The items table stores the
          # template only — per-slot data (enchantment, gems) lives in character_items.
          # upsert_all uses ON CONFLICT DO UPDATE, which Postgres rejects when two
          # input rows target the same existing row.
          item_records = items.filter_map { |raw_item| build_item_record(raw_item) }
                              .uniq { |r| r[:blizzard_id] }
                              .sort_by { |r| r[:blizzard_id] }
          return { "equipped_items" => {} } if item_records.empty?

          enchantment_source_blizzard_ids = items.filter_map { |raw_item|
            extract_enchantment_source_blizzard_id(raw_item)
          }.uniq.sort

          socket_gem_blizzard_ids = items.flat_map { |raw_item|
            extract_socket_gem_blizzard_ids(raw_item)
          }.uniq.sort

          enchantment_blizzard_ids = items.filter_map { |raw_item|
            extract_enchantment_blizzard_id(raw_item)
          }.uniq.sort

          # rubocop:disable Rails/SkipsModelValidations
          with_deadlock_retry do
            Item.upsert_all(item_records, unique_by: :blizzard_id, returning: false)
          end

          # Enchantment sources and socket gems are inserted as stubs — full metadata
          # (name, quality, class) is fetched later via a dedicated sync job.
          stub_item_blizzard_ids = (enchantment_source_blizzard_ids + socket_gem_blizzard_ids).uniq.sort -
                                   item_records.map { |r| r[:blizzard_id] }
          Item.insert_all(
            stub_item_blizzard_ids.map { |id| { blizzard_id: id } },
            unique_by: :blizzard_id
          ) if stub_item_blizzard_ids.any?

          # Enchantments are spell effects — they live in their own table.
          Enchantment.insert_all(
            enchantment_blizzard_ids.map { |id| { blizzard_id: id } },
            unique_by: :blizzard_id
          ) if enchantment_blizzard_ids.any?
          # rubocop:enable Rails/SkipsModelValidations

          all_item_blizzard_ids = (item_records.map { |r| r[:blizzard_id] } +
                                   enchantment_source_blizzard_ids +
                                   socket_gem_blizzard_ids).uniq
          items_by_blizzard_id        = fetch_item_ids_with_cache(all_item_blizzard_ids)
          enchantments_by_blizzard_id = fetch_enchantment_ids_with_cache(enchantment_blizzard_ids)

          # Equipped item names, socket gem names, and enchantment names are all
          # upserted in a single round-trip instead of three separate calls.
          upsert_all_translations(items_by_blizzard_id, enchantments_by_blizzard_id)

          equipped_items = {}
          items.each do |raw_item|
            slot        = raw_item.dig("slot", "type")&.downcase
            blizzard_id = extract_blizzard_id(raw_item)
            next unless slot && blizzard_id

            enc_src_blz_id = extract_enchantment_source_blizzard_id(raw_item)
            enc_blz_id     = extract_enchantment_blizzard_id(raw_item)

            equipped_items[slot] = {
              "blizzard_id" => blizzard_id,
              "item_id" => items_by_blizzard_id[blizzard_id],
              "item_level" => raw_item.dig("level", "value"),
              "name" => raw_item["name"],
              "quality" => raw_item.dig("quality", "type")&.downcase,
              "context" => raw_item["context"],
              "bonus_list" => raw_item["bonus_list"] || [],
              "enchantment_id" => enchantments_by_blizzard_id[enc_blz_id],
              "enchantment_source_item_id" => enc_src_blz_id ? items_by_blizzard_id[enc_src_blz_id] : nil,
              "embellishment_spell_id" => extract_embellishment_spell_id(raw_item),
              "sockets" => extract_sockets_with_ids(raw_item, items_by_blizzard_id),
              "crafting_stats" => extract_crafting_stats(raw_item),
              "stats" => extract_secondary_stats(raw_item)
            }
          end

          { "equipped_items" => equipped_items }
        end
        # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

        def item_level
          levels = items.map { |i| i.dig("level", "value") }.compact
          return if levels.empty?

          levels.sum / levels.size
        end

        def tier_set
          block = items.map { |i| i["set"] }.compact.first
          return unless block

          effects = block["effects"] || []

          {
            tier_set_id:     block.dig("item_set", "id"),
            tier_set_name:   block.dig("item_set", "name"),
            tier_set_pieces: (block["items"] || []).count { |x| x["is_equipped"] },
            tier_4p_active:  effects.any? { |eff| eff["required_count"] == 4 && eff["is_active"] }
          }
        end

        private

          attr_reader :items, :locale

          def valid_items(raw_equipment)
            Array(raw_equipment["equipped_items"]).select { |item| valid_item?(item) }
          end

          def valid_item?(raw_item)
            slot_type  = raw_item.dig("slot", "type")
            item_level = raw_item.dig("level", "value")
            !EXCLUDED_SLOTS.include?(slot_type) && item_level.to_i > 0
          end

          def build_item_record(raw_item)
            blizzard_id = extract_blizzard_id(raw_item)
            return nil unless blizzard_id

            {
              blizzard_id:       blizzard_id,
              inventory_type:    raw_item.dig("inventory_type", "type")&.downcase,
              item_class:        raw_item.dig("item_class", "name")&.downcase,
              item_subclass:     raw_item.dig("item_subclass", "name")&.downcase,
              blizzard_media_id: raw_item.dig("media", "id"),
              quality:           raw_item.dig("quality", "type")&.downcase
            }
          end

          # Cache blizzard_id → DB item id to avoid repeated DB hits across calls.
          # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
          def fetch_item_ids_with_cache(blizzard_ids)
            return {} if blizzard_ids.empty?

            cache_keys = blizzard_ids.index_with { |blz_id| "item:blz:#{blz_id}" }
            cached     = Rails.cache.read_multi(*cache_keys.values)

            result       = {}
            uncached_ids = []

            blizzard_ids.each do |blz_id|
              cached_value = cached[cache_keys[blz_id]]
              if cached_value
                result[blz_id] = cached_value
              else
                uncached_ids << blz_id
              end
            end

            if uncached_ids.any?
              db_rows = Item.where(blizzard_id: uncached_ids).pluck(:blizzard_id, :id).to_h
              result.merge!(db_rows)
              Rails.cache.write_multi(
                db_rows.transform_keys { |blz_id| "item:blz:#{blz_id}" },
                expires_in: CACHE_TTL
              )
            end

            result
          end

          def fetch_enchantment_ids_with_cache(blizzard_ids)
            return {} if blizzard_ids.empty?

            cache_keys = blizzard_ids.index_with { |blz_id| "enchantment:blz:#{blz_id}" }
            cached     = Rails.cache.read_multi(*cache_keys.values)

            result       = {}
            uncached_ids = []

            blizzard_ids.each do |blz_id|
              cached_value = cached[cache_keys[blz_id]]
              if cached_value
                result[blz_id] = cached_value
              else
                uncached_ids << blz_id
              end
            end

            if uncached_ids.any?
              db_rows = Enchantment.where(blizzard_id: uncached_ids).pluck(:blizzard_id, :id).to_h
              result.merge!(db_rows)
              Rails.cache.write_multi(
                db_rows.transform_keys { |blz_id| "enchantment:blz:#{blz_id}" },
                expires_in: CACHE_TTL
              )
            end

            result
          end
          # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

          def extract_blizzard_id(raw_item)
            raw_item.dig("item", "id")
          end

          def extract_enchantment_blizzard_id(raw_item)
            permanent = Array(raw_item["enchantments"])
              .find { |e| e.dig("enchantment_slot", "type") == "PERMANENT" }
            permanent&.dig("enchantment_id")
          end

          def extract_enchantment_source_blizzard_id(raw_item)
            permanent = Array(raw_item["enchantments"])
              .find { |e| e.dig("enchantment_slot", "type") == "PERMANENT" }
            permanent&.dig("source_item", "id")
          end

          def extract_socket_gem_blizzard_ids(raw_item)
            Array(raw_item["sockets"]).filter_map { |s| s.dig("item", "id") }
          end

          # Returns sockets with resolved DB item IDs and the gem's display string.
          def extract_sockets_with_ids(raw_item, items_by_blizzard_id)
            Array(raw_item["sockets"]).map do |socket|
              blizzard_gem_id = socket.dig("item", "id")
              {
                "type" => socket.dig("socket_type", "type"),
                "item_id" => blizzard_gem_id ? items_by_blizzard_id[blizzard_gem_id] : nil,
                "display_string" => socket["display_string"]
              }
            end
          end

          def extract_embellishment_spell_id(raw_item)
            Array(raw_item["spells"]).first&.dig("spell", "id")
          end

          def extract_crafting_stats(raw_item)
            Array(raw_item["modified_crafting_stat"]).map { |s| s["type"] }
          end

          def extract_secondary_stats(raw_item)
            Array(raw_item["stats"])
              .reject { |s| s["is_negated"] }
              .each_with_object({}) do |s, h|
                type = s.dig("type", "type")
                h[type] = s["value"].to_i if SECONDARY_STATS.include?(type)
              end
          end

          # Collect translations for equipped items, socket gems, and enchantments
          # then upsert them all in a single DB round-trip.
          # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
          def upsert_all_translations(items_by_blizzard_id, enchantments_by_blizzard_id)
            now     = Time.current
            records = []

            # Equipped item names
            items.each do |raw_item|
              blizzard_id = extract_blizzard_id(raw_item)
              name        = raw_item.dig("name")
              item_id     = items_by_blizzard_id[blizzard_id]
              next unless blizzard_id && name.present? && item_id

              records << { translatable_type: "Item", translatable_id: item_id,
                           key: "name", locale: locale, value: name,
                           meta: { source: "blizzard" }, created_at: now, updated_at: now }
            end

            # Socket gem names (from socket.item.name on each socket block)
            items.each do |raw_item|
              Array(raw_item["sockets"]).each do |socket|
                blizzard_gem_id = socket.dig("item", "id")
                gem_name        = socket.dig("item", "name")
                item_id         = items_by_blizzard_id[blizzard_gem_id]
                next unless blizzard_gem_id && gem_name.present? && item_id

                records << { translatable_type: "Item", translatable_id: item_id,
                             key: "name", locale: locale, value: gem_name,
                             meta: { source: "blizzard" }, created_at: now, updated_at: now }
              end
            end

            # Enchantment names (from display_string on PERMANENT enchantment blocks)
            items.each do |raw_item|
              enc_blz_id = extract_enchantment_blizzard_id(raw_item)
              next unless enc_blz_id

              enc_id = enchantments_by_blizzard_id[enc_blz_id]
              next unless enc_id

              permanent = Array(raw_item["enchantments"])
                .find { |e| e.dig("enchantment_slot", "type") == "PERMANENT" }
              raw_name = permanent&.dig("display_string")
              next unless raw_name.present?

              name = clean_enchantment_display_string(raw_name)
              next unless name.present?

              records << { translatable_type: "Enchantment", translatable_id: enc_id,
                           key: "name", locale: locale, value: name,
                           meta: { source: "blizzard" }, created_at: now, updated_at: now }
            end

            return if records.empty?

            unique_records = records
              .uniq { |r| [ r[:translatable_type], r[:translatable_id], r[:locale], r[:key] ] }
              .sort_by { |r| [ r[:translatable_type], r[:translatable_id].to_s, r[:locale], r[:key] ] }

            # rubocop:disable Rails/SkipsModelValidations
            with_deadlock_retry do
              Translation.upsert_all(unique_records, unique_by: %i[translatable_type translatable_id locale key])
            end
            # rubocop:enable Rails/SkipsModelValidations
          end

          # Strip Blizzard icon markup (|A:...|a) and the "Enchanted: " prefix.
          # "Enchanted: Chant of Leeching Fangs |A:Professions-...|a"
          #   → "Chant of Leeching Fangs"
          def clean_enchantment_display_string(display_string)
            display_string
              .gsub(/\|A:[^|]*\|a/i, "")
              .delete_prefix("Enchanted: ")
              .strip
          end
        # rubocop:enable Metrics/AbcSize, Metrics/MethodLength
      end
      # rubocop:enable Metrics/ClassLength
    end
  end
end
