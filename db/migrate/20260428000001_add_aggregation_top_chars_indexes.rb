class AddAggregationTopCharsIndexes < ActiveRecord::Migration[8.0]
  # The top_chars_cte used by all 4 aggregation services does:
  #   SELECT DISTINCT ON (l.bracket, e.character_id)
  #     e.character_id, l.bracket, e.spec_id, e.rating, ...
  #   FROM pvp_leaderboard_entries e
  #   JOIN pvp_leaderboards l ON l.id = e.pvp_leaderboard_id
  #   WHERE l.pvp_season_id = :season_id
  #     AND e.spec_id IS NOT NULL
  #     AND e.equipment_processed_at IS NOT NULL  (or specialization_processed_at)
  #   ORDER BY l.bracket, e.character_id, e.rating DESC
  #
  # PostgreSQL needs to resolve the DISTINCT ON by picking the highest-rated entry
  # per (bracket, character). With the index below, it can do a nested-loop index
  # scan per leaderboard — already sorted by (character_id, rating DESC) — making
  # the DISTINCT ON trivial (just take the first row per character_id).
  #
  # Without this index the planner does a hash join + sort on the full entries set
  # for each of the 4 parallel aggregation threads, causing unnecessary I/O.
  def change
    # Used by item, enchant, gem aggregation (equipment_processed_at filter)
    add_index :pvp_leaderboard_entries,
              "pvp_leaderboard_id, character_id, rating DESC",
              name: "idx_entries_top_chars_equipment",
              where: "spec_id IS NOT NULL AND equipment_processed_at IS NOT NULL"

    # Used by talent aggregation (specialization_processed_at filter)
    add_index :pvp_leaderboard_entries,
              "pvp_leaderboard_id, character_id, rating DESC",
              name: "idx_entries_top_chars_specialization",
              where: "spec_id IS NOT NULL AND specialization_processed_at IS NOT NULL"
  end
end
