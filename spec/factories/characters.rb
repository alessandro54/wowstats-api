# == Schema Information
#
# Table name: characters
# Database name: primary
#
#  id                          :bigint           not null, primary key
#  avatar_url                  :string
#  class_slug                  :string
#  equipment_last_modified     :datetime
#  faction                     :integer
#  inset_url                   :string
#  is_private                  :boolean          default(FALSE)
#  last_equipment_snapshot_at  :datetime
#  main_raw_url                :string
#  meta_synced_at              :datetime
#  name                        :string
#  race                        :string
#  realm                       :string
#  region                      :string
#  spec_equipment_fingerprints :jsonb
#  spec_talent_loadout_codes   :jsonb
#  stat_pcts                   :jsonb
#  talents_last_modified       :datetime
#  unavailable_until           :datetime
#  created_at                  :datetime         not null
#  updated_at                  :datetime         not null
#  blizzard_id                 :bigint
#  class_id                    :bigint
#  race_id                     :integer
#
# Indexes
#
#  index_characters_on_blizzard_id_and_region     (blizzard_id,region) UNIQUE
#  index_characters_on_is_private                 (is_private) WHERE (is_private = true)
#  index_characters_on_name_and_realm_and_region  (name,realm,region)
#  index_characters_on_stat_pcts                  (stat_pcts) USING gin
#  index_characters_on_unavailable_until_active   (unavailable_until) WHERE (unavailable_until IS NOT NULL)
#

# Parses spec/fixtures/{profile,equipment,specialization}/<char>.json to build
# character attributes and associated records. Keeps factories data-driven and
# avoids duplicating fixture data in both JSON files and hardcoded Ruby hashes.
module FixtureParser
  EXCLUDED_SLOTS = %w[TABARD SHIRT].freeze unless defined?(EXCLUDED_SLOTS)

  # Sets character attributes from profile/<char_name>.json onto an unsaved record.
  def self.apply_profile(character, char_name)
    raw    = load("profile/#{char_name}.json")
    region = raw.dig("_links", "self", "href").to_s[/https?:\/\/(\w+)\.api\.blizzard\.com/, 1]

    character.assign_attributes(
      blizzard_id: raw["id"].to_s,
      name:        raw["name"],
      realm:       raw.dig("realm", "slug"),
      region:      region,
      race:        raw.dig("race", "name")&.downcase,
      class_slug:  raw.dig("character_class", "name")&.downcase,
      class_id:    raw.dig("character_class", "id"),
      race_id:     raw.dig("race", "id"),
      faction:     raw.dig("faction", "type") == "ALLIANCE" ? 0 : 1
    )
  end

  # Creates CharacterItem records for every non-excluded slot in equipment/<char_name>.json.
  # Items, enchantments, and gem items are found-or-created by blizzard_id so the
  # method is safe to invoke in parallel test runs without unique-constraint errors.
  # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
  def self.build_equipment(character, char_name, spec_id: nil)
    raw = load("specialization/#{char_name}.json")
    spec_id ||= raw.dig("active_specialization", "id") || 262

    raw_items = load("equipment/#{char_name}.json")["equipped_items"].reject { |i|
      EXCLUDED_SLOTS.include?(i.dig("slot", "type")) || i.dig("level", "value").to_i <= 0
    }

    item_map    = build_item_map(raw_items)
    enchant_map = build_enchant_map(raw_items)

    raw_items.each do |raw_item|
      permanent = Array(raw_item["enchantments"]).find { |e| e.dig("enchantment_slot", "type") == "PERMANENT" }
      sockets   = Array(raw_item["sockets"]).map { |s|
        { "type" => s.dig("socket_type", "type"), "item_id" => item_map[s.dig("item", "id")]&.id,
"display_string" => s["display_string"] }
      }

      CharacterItem.create!(
        character:               character,
        item:                    item_map[raw_item.dig("item", "id")],
        slot:                    raw_item.dig("slot", "type"),
        spec_id:                 spec_id,
        item_level:              raw_item.dig("level", "value").to_i,
        context:                 raw_item["context"],
        enchantment:             enchant_map[permanent&.dig("enchantment_id")],
        enchantment_source_item: item_map[permanent&.dig("source_item", "id")],
        bonus_list:              raw_item["bonus_list"] || [],
        sockets:                 sockets,
        crafting_stats:          []
      )
    end
  end
  # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

  # Creates Talent and CharacterTalent records from the active loadout in
  # specialization/<char_name>.json. Also writes talent_loadout_code to the character.
  # rubocop:disable Metrics/AbcSize
  def self.build_talents(character, char_name)
    raw     = load("specialization/#{char_name}.json")
    spec_id = raw.dig("active_specialization", "id")
    spec    = raw["specializations"].find { |s| s.dig("specialization", "id") == spec_id }
    return unless spec

    loadout = spec["loadouts"].find { |l| l["is_active"] } || spec["loadouts"].first
    return unless loadout

    new_codes = (character.spec_talent_loadout_codes || {}).merge(spec_id.to_s => loadout["talent_loadout_code"])
    character.update_columns(spec_talent_loadout_codes: new_codes) # rubocop:disable Rails/SkipsModelValidations

    { "selected_class_talents" => "class", "selected_spec_talents" => "spec",
"selected_hero_talents" => "hero" }.each do |key, type|
      Array(loadout[key]).each do |t|
        talent = Talent.find_or_create_by!(blizzard_id: t["id"]) { |rec| rec.talent_type = type }
        CharacterTalent.create!(character: character, talent: talent, talent_type: type, rank: t["rank"],
spec_id: spec_id)
      end
    end
  end
  # rubocop:enable Metrics/AbcSize

  class << self
    private

      def load(path)
        JSON.parse(File.read(Rails.root.join("spec/fixtures", path)))
      end

      # Builds a blizzard_id → Item map covering equipped items, gem items, and
      # enchant source items. Equipped items get full attributes from the JSON;
      # supporting items (gems, enchant sources) are created with nil attrs.
      # rubocop:disable Metrics/AbcSize
      def build_item_map(raw_items)
        equipped_by_id = raw_items.index_by { |i| i.dig("item", "id") }

        all_ids = (
          raw_items.map { |i| i.dig("item", "id") } +
          raw_items.flat_map { |i| Array(i["sockets"]).filter_map { |s| s.dig("item", "id") } } +
          raw_items.filter_map { |i| Array(i["enchantments"]).find { |e|
 e.dig("enchantment_slot", "type") == "PERMANENT" }&.dig("source_item", "id") }
        ).compact.uniq

        all_ids.index_with do |bid|
          raw = equipped_by_id[bid]
          Item.find_or_create_by!(blizzard_id: bid) do |i|
            next unless raw

            i.item_class     = raw.dig("item_class", "name")&.downcase
            i.item_subclass  = raw.dig("item_subclass", "name")&.downcase
            i.inventory_type = raw.dig("inventory_type", "type")&.downcase
            i.quality        = raw.dig("quality", "type")&.downcase
          end
        end
      end
      # rubocop:enable Metrics/AbcSize

      def build_enchant_map(raw_items)
        ids = raw_items.filter_map { |i|
          Array(i["enchantments"]).find { |e| e.dig("enchantment_slot", "type") == "PERMANENT" }&.dig("enchantment_id")
        }.uniq
        ids.index_with { |bid| Enchantment.find_or_create_by!(blizzard_id: bid) }
      end
  end
end

FactoryBot.define do
  factory :character do
    name        { Faker::Name.middle_name }
    realm       { Faker::Games::WorldOfWarcraft.hero.split(" ").first.downcase }
    region      { %w[us eu kr tw].sample }
    race        { Faker::Games::WorldOfWarcraft.race.downcase }
    class_slug  { Faker::Games::WorldOfWarcraft.class_name.downcase }
    blizzard_id { Faker::Number.number(digits: 8).to_s }
    faction     { [ 0, 1 ].sample }

    transient { fixture_name { nil } }

    # Night Elf Discipline Priest on Sargeras-US (Alliance)
    trait :motivate do
      fixture_name { "motívate" }
      after(:build) { |char| FixtureParser.apply_profile(char, "motívate") }
    end

    # Night Elf Subtlety Rogue on Malorne-US (Alliance)
    trait :jw do
      fixture_name { "jw" }
      after(:build) { |char| FixtureParser.apply_profile(char, "jw") }
    end

    # Night Elf Assassination Rogue on Sargeras-US (Alliance)
    trait :egirlbooster do
      fixture_name { "egirlbooster" }
      after(:build) { |char| FixtureParser.apply_profile(char, "egirlbooster") }
    end

    # Builds CharacterItem records from equipment/<fixture_name>.json.
    # Requires a character trait (:motivate, :jw, :egirlbooster) to be applied first.
    trait :with_full_equipment do
      after(:create) do |char, evaluator|
        FixtureParser.build_equipment(char, evaluator.fixture_name)
      end
    end

    # Builds Talent/CharacterTalent records from specialization/<fixture_name>.json.
    # Requires a character trait (:motivate, :jw, :egirlbooster) to be applied first.
    trait :with_full_talents do
      after(:create) do |char, evaluator|
        FixtureParser.build_talents(char, evaluator.fixture_name)
      end
    end
  end
end
