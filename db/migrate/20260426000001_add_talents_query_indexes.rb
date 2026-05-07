class AddTalentsQueryIndexes < ActiveRecord::Migration[8.0]
  def change
    # COUNT(DISTINCT character_id) in count_raw_players — covering index for the partial scan
    add_index :pvp_leaderboard_entries,
              %i[pvp_leaderboard_id spec_id character_id],
              name: "idx_entries_for_talent_player_count",
              where: "specialization_processed_at IS NOT NULL"

    # CharacterTalent.where(spec_id:, talent_type: "pvp").distinct.pluck(:talent_id)
    add_index :character_talents,
              %i[spec_id talent_type talent_id],
              name: "idx_character_talents_spec_type_talent"
  end
end
