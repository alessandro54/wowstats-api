class DropDeadTalentFkIndex < ActiveRecord::Migration[8.1]
  # index_character_talents_on_talent_id — 152MB, used only by autovacuum (1 scan since restore).
  # FK cascade on talent deletions is rare (only SyncTalentTreesJob).
  # Dropping saves write amplification on every rebuild_character_talents call.
  def change
    remove_index :character_talents, :talent_id,
                 name: "index_character_talents_on_talent_id",
                 if_exists: true
  end
end
