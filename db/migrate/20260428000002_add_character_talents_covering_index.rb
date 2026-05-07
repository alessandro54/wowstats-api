class AddCharacterTalentsCoveringIndex < ActiveRecord::Migration[8.0]
  # The talent aggregation char_builds CTE does 68k nested-loop index scans
  # into character_talents for (character_id, spec_id, rank > 0), then fetches
  # talent_id from the heap — 253k disk reads per aggregation run.
  #
  # A covering index (INCLUDE talent_id) WHERE rank > 0 turns this into an
  # index-only scan: no heap fetches, the index is small enough to stay in cache.
  def change
    add_index :character_talents,
              %i[character_id spec_id],
              include: :talent_id,
              name:    "idx_character_talents_covering_for_agg",
              where:   "rank > 0"
  end
end
