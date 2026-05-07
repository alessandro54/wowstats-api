module Characters
  class ShowSerializer
    def initialize(character, pvp_entries:, primary_spec_id:, locale: "en_US")
      @character       = character
      @pvp_entries     = pvp_entries
      @primary_spec_id = primary_spec_id
      @locale          = locale
    end

    def call
      base_fields.merge(
        pvp_entries:         serialize_pvp_entries,
        equipment:           primary_spec_id ? build_equipment : [],
        talents:             primary_spec_id ? build_talents : [],
        talent_loadout_code: talent_loadout_code_for_primary_spec
      )
    end

    private

      attr_reader :character, :pvp_entries, :primary_spec_id, :locale

      def base_fields
        character_identity.merge(character_appearance).merge(
          primary_spec_id: primary_spec_id,
          stat_pcts:       character.stat_pcts || {}
        )
      end

      # WoW in-game import string for the primary spec's talent loadout.
      # Stored per-spec by ProcessSpecializationService; lookup is by string
      # key because spec_talent_loadout_codes is a JSONB column.
      def talent_loadout_code_for_primary_spec
        return nil unless primary_spec_id

        character.spec_talent_loadout_codes&.[](primary_spec_id.to_s)
      end

      def character_identity
        { name: character.name, realm: character.realm,
          region: character.region.upcase, class_slug: character.class_slug.to_s.tr("_", "-").presence,
          race: character.race, faction: character.faction }
      end

      def character_appearance
        { avatar_url: character.avatar_url, inset_url: character.inset_url }
      end

      def serialize_pvp_entries
        pvp_entries.map do |e|
          { bracket: e.bracket, region: e.region.upcase, rating: e.rating,
            wins: e.wins, losses: e.losses, rank: e.rank, spec_id: e.spec_id }
        end
      end

      def build_equipment
        items = character.character_items.where(spec_id: primary_spec_id).includes(:item)
        return [] if items.empty?

        item_names    = fetch_translation_names("Item", items.map(&:item_id))
        enchant_names = fetch_translation_names("Enchantment", items.filter_map(&:enchantment_id))
        gem_icons, gem_names = fetch_gem_data(items)

        items.map { |ci| serialize_equipment_item(ci, item_names, enchant_names, gem_icons, gem_names) }
      end

      def fetch_gem_data(items)
        ids = items.flat_map { |ci| Array(ci.sockets).filter_map { |s| s["item_id"] } }.uniq
        return [ {}, {} ] if ids.empty?

        [ Item.where(id: ids).pluck(:id, :icon_url).to_h, fetch_translation_names("Item", ids) ]
      end

      def fetch_translation_names(type, ids)
        return {} if ids.empty?

        Translation
          .where(translatable_type: type, translatable_id: ids, key: "name", locale: locale)
          .pluck(:translatable_id, :value).to_h
      end

      def serialize_equipment_item(ci, item_names, enchant_names, gem_icons, gem_names)
        { slot: ci.slot, item_level: ci.item_level, quality: ci.item&.quality,
          blizzard_id: ci.item&.blizzard_id, name: item_names[ci.item_id],
          icon_url: ci.item&.icon_url, enchant: enchant_names[ci.enchantment_id],
          sockets: serialize_sockets(ci.sockets, gem_icons, gem_names) }
      end

      def serialize_sockets(sockets, gem_icons, gem_names)
        Array(sockets).filter_map do |s|
          name = (s["item_id"] && gem_names[s["item_id"]]) || s["display_string"].presence
          { name: name, icon_url: gem_icons[s["item_id"]] } if name
        end
      end

      def build_talents
        all_talent_ids = TalentSpecAssignment.where(spec_id: primary_spec_id).pluck(:talent_id)
        return [] if all_talent_ids.empty?

        selected    = load_selected_talents
        all_ids     = expand_talent_ids(all_talent_ids, selected)
        all_talents = Talent.includes(:translations).where(id: all_ids)
        prereqs     = load_talent_prerequisites(all_talents)
        default_pts = load_default_points(all_ids)
        all_talents.map { |t| serialize_talent_entry(t, selected, prereqs, default_pts) }
      end

      def expand_talent_ids(base_ids, selected)
        pvp_extra = selected.keys.select { |tid| selected.dig(tid, :type) == "pvp" } - base_ids
        base_ids + pvp_extra
      end

      def load_default_points(all_ids)
        TalentSpecAssignment
          .where(talent_id: all_ids, spec_id: primary_spec_id)
          .pluck(:talent_id, :default_points).to_h
      end

      def load_selected_talents
        CharacterTalent
          .where(character_id: character.id, spec_id: primary_spec_id)
          .pluck(:talent_id, :talent_type, :rank, :slot_number)
          .to_h { |(tid, ttype, rank, slot)| [ tid, { type: ttype, rank: rank, slot: slot } ] }
      end

      def load_talent_prerequisites(talents)
        node_ids = talents.filter_map(&:node_id).uniq
        return {} if node_ids.empty?

        TalentPrerequisite.where(node_id: node_ids)
          .group_by(&:node_id)
          .transform_values { |ps| ps.map(&:prerequisite_node_id) }
      end

      def serialize_talent_entry(t, selected, prereqs, default_pts)
        ct = selected[t.id]
        { id:             nil,
          talent:         build_talent_hash(t, prereqs, default_pts),
          usage_count:    ct ? (ct[:rank] || 1) : 0,
          usage_pct:      ct ? 1.0 : 0.0,
          in_top_build:   ct.present?,
          top_build_rank: ct ? (ct[:rank] || 0) : 0,
          tier:           ct ? "bis" : "common",
          snapshot_at:    nil }
      end

      def build_talent_hash(t, prereqs, default_pts)
        { id: t.id, blizzard_id: t.blizzard_id,
          name: t.t("name", locale: locale),
          description: t.t("description", locale: locale),
          talent_type: t.talent_type, spell_id: t.spell_id,
          node_id: t.node_id, display_row: t.display_row,
          display_col: t.display_col, max_rank: t.max_rank,
          icon_url: t.icon_url,
          default_points: default_pts[t.id] || 0,
          prerequisite_node_ids: prereqs[t.node_id] || [] }
      end
  end
end
