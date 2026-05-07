class DropRedundantCharacterTalentsCharSpecIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # Redundant with idx_character_talents_covering_for_agg, which has the same
  # leading columns (character_id, spec_id) and additionally INCLUDEs talent_id.
  # Frees ~96 MB on prod.
  def up
    remove_index :character_talents,
                 name: :idx_character_talents_on_char_spec,
                 algorithm: :concurrently,
                 if_exists: true
  end

  def down
    add_index :character_talents,
              %i[character_id spec_id],
              name: :idx_character_talents_on_char_spec,
              algorithm: :concurrently,
              if_not_exists: true
  end
end
