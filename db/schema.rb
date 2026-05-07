# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_05_01_000001) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "character_items", force: :cascade do |t|
    t.integer "bonus_list", default: [], array: true
    t.bigint "character_id", null: false
    t.integer "context"
    t.string "crafting_stats", default: [], array: true
    t.datetime "created_at", null: false
    t.integer "embellishment_spell_id"
    t.bigint "enchantment_id"
    t.bigint "enchantment_source_item_id"
    t.bigint "item_id", null: false
    t.integer "item_level"
    t.string "slot", null: false
    t.jsonb "sockets", default: []
    t.integer "spec_id", null: false
    t.jsonb "stats", default: {}
    t.datetime "updated_at", null: false
    t.index ["character_id", "slot", "spec_id"], name: "idx_character_items_on_char_slot_spec", unique: true
    t.index ["character_id", "spec_id"], name: "idx_character_items_on_char_spec"
    t.index ["enchantment_id"], name: "index_character_items_on_enchantment_id", where: "(enchantment_id IS NOT NULL)"
    t.index ["item_id"], name: "index_character_items_on_item_id"
  end

  create_table "character_talents", force: :cascade do |t|
    t.bigint "character_id", null: false
    t.datetime "created_at", null: false
    t.integer "rank", default: 1
    t.integer "slot_number"
    t.integer "spec_id", null: false
    t.bigint "talent_id", null: false
    t.string "talent_type", null: false
    t.datetime "updated_at", null: false
    t.index ["character_id", "spec_id"], name: "idx_character_talents_covering_for_agg", where: "(rank > 0)", include: ["talent_id"]
    t.index ["character_id", "spec_id"], name: "idx_character_talents_on_char_spec"
    t.index ["character_id", "talent_id", "spec_id"], name: "idx_character_talents_on_char_talent_spec", unique: true
    t.index ["character_id", "talent_type"], name: "idx_character_talents_on_char_and_type"
    t.index ["spec_id", "talent_type", "talent_id"], name: "idx_character_talents_spec_type_talent"
    t.index ["talent_id"], name: "index_character_talents_on_talent_id"
  end

  create_table "characters", force: :cascade do |t|
    t.string "avatar_url"
    t.bigint "blizzard_id"
    t.bigint "class_id"
    t.string "class_slug"
    t.datetime "created_at", null: false
    t.datetime "equipment_last_modified", precision: nil
    t.integer "faction"
    t.string "inset_url"
    t.boolean "is_private", default: false
    t.datetime "last_equipment_snapshot_at"
    t.string "main_raw_url"
    t.datetime "meta_synced_at"
    t.string "name"
    t.string "race"
    t.integer "race_id"
    t.string "realm"
    t.string "region"
    t.jsonb "spec_equipment_fingerprints", default: {}
    t.jsonb "spec_talent_loadout_codes", default: {}
    t.jsonb "stat_pcts", default: {}
    t.datetime "talents_last_modified", precision: nil
    t.datetime "unavailable_until"
    t.datetime "updated_at", null: false
    t.index ["blizzard_id", "region"], name: "index_characters_on_blizzard_id_and_region", unique: true
    t.index ["is_private"], name: "index_characters_on_is_private", where: "(is_private = true)"
    t.index ["name", "realm", "region"], name: "index_characters_on_name_and_realm_and_region"
    t.index ["stat_pcts"], name: "index_characters_on_stat_pcts", using: :gin
    t.index ["unavailable_until"], name: "index_characters_on_unavailable_until_active", where: "(unavailable_until IS NOT NULL)"
  end

  create_table "enchantments", force: :cascade do |t|
    t.bigint "blizzard_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["blizzard_id"], name: "index_enchantments_on_blizzard_id", unique: true
  end

  create_table "items", force: :cascade do |t|
    t.bigint "blizzard_id", null: false
    t.bigint "blizzard_media_id"
    t.datetime "created_at", null: false
    t.string "icon_url"
    t.string "inventory_type"
    t.string "item_class"
    t.string "item_subclass"
    t.datetime "meta_synced_at"
    t.string "quality"
    t.datetime "updated_at", null: false
    t.index ["blizzard_id"], name: "index_items_on_blizzard_id", unique: true
  end

  create_table "job_performance_metrics", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.float "duration", null: false
    t.string "error_class"
    t.string "job_class", null: false
    t.boolean "success", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_job_performance_metrics_on_created_at"
    t.index ["job_class", "created_at"], name: "index_job_performance_metrics_on_job_class_and_created_at"
    t.index ["job_class"], name: "index_job_performance_metrics_on_job_class"
    t.index ["success"], name: "index_job_performance_metrics_on_success"
  end

  create_table "pvp_leaderboard_entries", force: :cascade do |t|
    t.bigint "character_id", null: false
    t.datetime "created_at", null: false
    t.datetime "equipment_processed_at"
    t.integer "hero_talent_tree_id"
    t.string "hero_talent_tree_name"
    t.integer "item_level"
    t.integer "losses", default: 0
    t.bigint "pvp_leaderboard_id", null: false
    t.integer "rank"
    t.integer "rating"
    t.datetime "snapshot_at"
    t.integer "spec_id"
    t.datetime "specialization_processed_at"
    t.integer "sync_retry_count", default: 0, null: false
    t.boolean "tier_4p_active", default: false
    t.integer "tier_set_id"
    t.string "tier_set_name"
    t.integer "tier_set_pieces"
    t.datetime "updated_at", null: false
    t.integer "wins", default: 0
    t.index ["character_id", "equipment_processed_at"], name: "index_pvp_entries_on_character_and_equipment_processed", where: "(equipment_processed_at IS NOT NULL)"
    t.index ["character_id", "pvp_leaderboard_id"], name: "idx_entries_unique_char_leaderboard", unique: true
    t.index ["character_id"], name: "index_pvp_leaderboard_entries_on_character_id"
    t.index ["hero_talent_tree_id"], name: "index_pvp_leaderboard_entries_on_hero_talent_tree_id"
    t.index ["id", "equipment_processed_at"], name: "index_entries_for_batch_processing"
    t.index ["pvp_leaderboard_id", "character_id", "rating"], name: "idx_entries_top_chars_equipment", order: { rating: :desc }, where: "((spec_id IS NOT NULL) AND (equipment_processed_at IS NOT NULL))"
    t.index ["pvp_leaderboard_id", "character_id", "rating"], name: "idx_entries_top_chars_specialization", order: { rating: :desc }, where: "((spec_id IS NOT NULL) AND (specialization_processed_at IS NOT NULL))"
    t.index ["pvp_leaderboard_id", "rating"], name: "index_entries_on_leaderboard_and_rating"
    t.index ["pvp_leaderboard_id", "spec_id", "character_id"], name: "idx_entries_for_talent_player_count", where: "(specialization_processed_at IS NOT NULL)"
    t.index ["pvp_leaderboard_id", "spec_id", "rating"], name: "index_entries_for_spec_meta"
    t.index ["pvp_leaderboard_id"], name: "index_pvp_leaderboard_entries_on_pvp_leaderboard_id"
    t.index ["rank"], name: "index_pvp_leaderboard_entries_on_rank"
    t.index ["tier_set_id"], name: "index_pvp_leaderboard_entries_on_tier_set_id"
  end

  create_table "pvp_leaderboards", force: :cascade do |t|
    t.string "bracket"
    t.datetime "created_at", null: false
    t.datetime "last_synced_at"
    t.bigint "pvp_season_id", null: false
    t.string "region"
    t.datetime "updated_at", null: false
    t.index ["pvp_season_id", "bracket", "region"], name: "idx_leaderboards_season_bracket_region", unique: true
    t.index ["pvp_season_id"], name: "index_pvp_leaderboards_on_pvp_season_id"
  end

  create_table "pvp_meta_enchant_popularity", force: :cascade do |t|
    t.string "bracket", null: false
    t.datetime "created_at", null: false
    t.bigint "enchantment_id", null: false
    t.decimal "prev_usage_pct", precision: 5, scale: 2
    t.bigint "pvp_season_id", null: false
    t.bigint "pvp_sync_cycle_id"
    t.string "slot", null: false
    t.datetime "snapshot_at", null: false
    t.integer "spec_id", null: false
    t.datetime "updated_at", null: false
    t.integer "usage_count", default: 0, null: false
    t.decimal "usage_pct", precision: 5, scale: 2
    t.index ["enchantment_id"], name: "index_pvp_meta_enchant_popularity_on_enchantment_id"
    t.index ["pvp_season_id", "bracket", "spec_id", "slot", "enchantment_id"], name: "idx_meta_enchant_unique_no_cycle", unique: true, where: "(pvp_sync_cycle_id IS NULL)"
    t.index ["pvp_season_id", "bracket", "spec_id", "slot"], name: "idx_meta_enchant_lookup"
    t.index ["pvp_season_id"], name: "index_pvp_meta_enchant_popularity_on_pvp_season_id"
    t.index ["pvp_sync_cycle_id", "bracket", "spec_id", "slot", "enchantment_id"], name: "idx_meta_enchant_unique_cycle", unique: true, where: "(pvp_sync_cycle_id IS NOT NULL)"
    t.index ["pvp_sync_cycle_id"], name: "index_pvp_meta_enchant_popularity_on_pvp_sync_cycle_id"
  end

  create_table "pvp_meta_gem_popularity", force: :cascade do |t|
    t.string "bracket", null: false
    t.datetime "created_at", null: false
    t.bigint "item_id", null: false
    t.decimal "prev_usage_pct", precision: 5, scale: 2
    t.bigint "pvp_season_id", null: false
    t.bigint "pvp_sync_cycle_id"
    t.string "slot", null: false
    t.datetime "snapshot_at", null: false
    t.string "socket_type", null: false
    t.integer "spec_id", null: false
    t.datetime "updated_at", null: false
    t.integer "usage_count", default: 0, null: false
    t.decimal "usage_pct", precision: 5, scale: 2
    t.index ["item_id"], name: "index_pvp_meta_gem_popularity_on_item_id"
    t.index ["pvp_season_id", "bracket", "spec_id", "slot", "socket_type", "item_id"], name: "idx_meta_gem_unique_no_cycle", unique: true, where: "(pvp_sync_cycle_id IS NULL)"
    t.index ["pvp_season_id", "bracket", "spec_id", "slot"], name: "idx_meta_gem_lookup"
    t.index ["pvp_season_id"], name: "index_pvp_meta_gem_popularity_on_pvp_season_id"
    t.index ["pvp_sync_cycle_id", "bracket", "spec_id", "slot", "socket_type", "item_id"], name: "idx_meta_gem_unique_cycle", unique: true, where: "(pvp_sync_cycle_id IS NOT NULL)"
    t.index ["pvp_sync_cycle_id"], name: "index_pvp_meta_gem_popularity_on_pvp_sync_cycle_id"
  end

  create_table "pvp_meta_item_popularity", force: :cascade do |t|
    t.string "bracket", null: false
    t.datetime "created_at", null: false
    t.bigint "item_id", null: false
    t.decimal "prev_usage_pct", precision: 5, scale: 2
    t.bigint "pvp_season_id", null: false
    t.bigint "pvp_sync_cycle_id"
    t.string "slot", null: false
    t.datetime "snapshot_at", null: false
    t.integer "spec_id", null: false
    t.datetime "updated_at", null: false
    t.integer "usage_count", default: 0, null: false
    t.decimal "usage_pct", precision: 5, scale: 2
    t.index ["item_id"], name: "index_pvp_meta_item_popularity_on_item_id"
    t.index ["pvp_season_id", "bracket", "spec_id", "slot", "item_id"], name: "idx_meta_item_unique_no_cycle", unique: true, where: "(pvp_sync_cycle_id IS NULL)"
    t.index ["pvp_season_id", "bracket", "spec_id", "slot"], name: "idx_meta_item_lookup"
    t.index ["pvp_season_id"], name: "index_pvp_meta_item_popularity_on_pvp_season_id"
    t.index ["pvp_sync_cycle_id", "bracket", "spec_id", "slot", "item_id"], name: "idx_meta_item_unique_cycle", unique: true, where: "(pvp_sync_cycle_id IS NOT NULL)"
    t.index ["pvp_sync_cycle_id"], name: "index_pvp_meta_item_popularity_on_pvp_sync_cycle_id"
  end

  create_table "pvp_meta_talent_popularity", force: :cascade do |t|
    t.string "bracket", null: false
    t.datetime "created_at", null: false
    t.boolean "in_top_build", default: false, null: false
    t.bigint "pvp_season_id", null: false
    t.bigint "pvp_sync_cycle_id"
    t.datetime "snapshot_at", null: false
    t.integer "spec_id", null: false
    t.bigint "talent_id", null: false
    t.string "talent_type", null: false
    t.string "tier", default: "common", null: false
    t.integer "top_build_rank", default: 0, null: false
    t.datetime "updated_at", null: false
    t.integer "usage_count", default: 0, null: false
    t.decimal "usage_pct", precision: 8, scale: 4
    t.index ["pvp_season_id", "bracket", "spec_id", "talent_id"], name: "idx_meta_talent_unique_no_cycle", unique: true, where: "(pvp_sync_cycle_id IS NULL)"
    t.index ["pvp_season_id", "bracket", "spec_id", "talent_type"], name: "idx_meta_talent_lookup"
    t.index ["pvp_season_id"], name: "index_pvp_meta_talent_popularity_on_pvp_season_id"
    t.index ["pvp_sync_cycle_id", "bracket", "spec_id", "talent_id"], name: "idx_meta_talent_unique_cycle", unique: true, where: "(pvp_sync_cycle_id IS NOT NULL)"
    t.index ["pvp_sync_cycle_id"], name: "index_pvp_meta_talent_popularity_on_pvp_sync_cycle_id"
    t.index ["talent_id"], name: "index_pvp_meta_talent_popularity_on_talent_id"
  end

  create_table "pvp_seasons", force: :cascade do |t|
    t.integer "blizzard_id"
    t.datetime "created_at", null: false
    t.string "display_name"
    t.datetime "end_time"
    t.boolean "is_current", default: false
    t.bigint "live_pvp_sync_cycle_id"
    t.datetime "start_time"
    t.datetime "updated_at", null: false
    t.index ["blizzard_id"], name: "index_pvp_seasons_on_blizzard_id", unique: true
    t.index ["is_current"], name: "index_pvp_seasons_on_is_current"
    t.index ["live_pvp_sync_cycle_id"], name: "index_pvp_seasons_on_live_pvp_sync_cycle_id"
    t.index ["updated_at"], name: "index_pvp_seasons_on_updated_at"
  end

  create_table "pvp_sync_cycles", force: :cascade do |t|
    t.datetime "completed_at"
    t.integer "completed_character_batches", default: 0, null: false
    t.datetime "created_at", null: false
    t.integer "expected_character_batches", default: 0, null: false
    t.bigint "pvp_season_id", null: false
    t.string "regions", default: [], null: false, array: true
    t.datetime "snapshot_at", null: false
    t.string "status", default: "syncing_leaderboards", null: false
    t.datetime "updated_at", null: false
    t.index ["pvp_season_id", "status"], name: "index_pvp_sync_cycles_on_pvp_season_id_and_status"
    t.index ["pvp_season_id"], name: "index_pvp_sync_cycles_on_pvp_season_id"
  end

  create_table "talent_prerequisites", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "node_id", null: false
    t.bigint "prerequisite_node_id", null: false
    t.datetime "updated_at", null: false
    t.index ["node_id", "prerequisite_node_id"], name: "idx_talent_prerequisites_unique", unique: true
    t.index ["node_id"], name: "index_talent_prerequisites_on_node_id"
  end

  create_table "talent_spec_assignments", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "default_points", default: 0, null: false
    t.integer "spec_id", null: false
    t.bigint "talent_id", null: false
    t.datetime "updated_at", null: false
    t.index ["spec_id"], name: "index_talent_spec_assignments_on_spec_id"
    t.index ["talent_id", "spec_id"], name: "index_talent_spec_assignments_on_talent_id_and_spec_id", unique: true
  end

  create_table "talent_sync_runs", force: :cascade do |t|
    t.datetime "completed_at"
    t.jsonb "counts", default: {}, null: false
    t.datetime "created_at", null: false
    t.text "error_message"
    t.jsonb "failed_specs", default: [], null: false
    t.boolean "force", default: false, null: false
    t.string "locale", null: false
    t.string "region", null: false
    t.jsonb "regression", default: {}, null: false
    t.datetime "started_at", null: false
    t.string "status", default: "running", null: false
    t.jsonb "tsa_counts", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["started_at"], name: "index_talent_sync_runs_on_started_at"
    t.index ["status", "started_at"], name: "index_talent_sync_runs_on_status_and_started_at"
  end

  create_table "talents", force: :cascade do |t|
    t.bigint "blizzard_id", null: false
    t.datetime "created_at", null: false
    t.integer "display_col"
    t.integer "display_row"
    t.string "icon_url"
    t.integer "max_rank", default: 1, null: false
    t.bigint "node_id"
    t.integer "spell_id"
    t.string "talent_type", null: false
    t.datetime "updated_at", null: false
    t.index ["blizzard_id"], name: "index_talents_on_blizzard_id", unique: true
    t.index ["node_id"], name: "index_talents_on_node_id"
  end

  create_table "translations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.string "locale", null: false
    t.jsonb "meta", default: {}, null: false
    t.bigint "translatable_id", null: false
    t.string "translatable_type", null: false
    t.datetime "updated_at", null: false
    t.text "value", null: false
    t.index ["key"], name: "index_translations_on_key"
    t.index ["locale"], name: "index_translations_on_locale"
    t.index ["translatable_type", "translatable_id", "locale", "key"], name: "index_translations_on_translatable_and_locale_and_key", unique: true
    t.index ["translatable_type", "translatable_id"], name: "index_translations_on_translatable"
  end

  add_foreign_key "character_items", "characters"
  add_foreign_key "character_items", "enchantments"
  add_foreign_key "character_items", "items"
  add_foreign_key "character_items", "items", column: "enchantment_source_item_id"
  add_foreign_key "character_talents", "characters"
  add_foreign_key "character_talents", "talents"
  add_foreign_key "pvp_leaderboard_entries", "characters"
  add_foreign_key "pvp_leaderboard_entries", "pvp_leaderboards"
  add_foreign_key "pvp_leaderboards", "pvp_seasons"
  add_foreign_key "pvp_meta_enchant_popularity", "enchantments"
  add_foreign_key "pvp_meta_enchant_popularity", "pvp_seasons"
  add_foreign_key "pvp_meta_enchant_popularity", "pvp_sync_cycles"
  add_foreign_key "pvp_meta_gem_popularity", "items"
  add_foreign_key "pvp_meta_gem_popularity", "pvp_seasons"
  add_foreign_key "pvp_meta_gem_popularity", "pvp_sync_cycles"
  add_foreign_key "pvp_meta_item_popularity", "items"
  add_foreign_key "pvp_meta_item_popularity", "pvp_seasons"
  add_foreign_key "pvp_meta_item_popularity", "pvp_sync_cycles"
  add_foreign_key "pvp_meta_talent_popularity", "pvp_seasons"
  add_foreign_key "pvp_meta_talent_popularity", "pvp_sync_cycles"
  add_foreign_key "pvp_meta_talent_popularity", "talents"
  add_foreign_key "pvp_seasons", "pvp_sync_cycles", column: "live_pvp_sync_cycle_id"
  add_foreign_key "pvp_sync_cycles", "pvp_seasons"
  add_foreign_key "talent_spec_assignments", "talents"
end
