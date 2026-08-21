class DropRedundantSnapshotIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  TABLE       = :pvp_leaderboard_entry_snapshots
  CHAR_IDX    = "index_pvp_leaderboard_entry_snapshots_on_character_id".freeze
  LEADER_IDX  = "index_pvp_leaderboard_entry_snapshots_on_pvp_leaderboard_id".freeze

  # Both single-column indexes are the leftmost prefix of an existing composite
  # index, so the planner never needs them:
  #   on_character_id        <= idx_snap_character_time   (character_id, snapshot_at DESC)
  #   on_pvp_leaderboard_id  <= idx_snap_leaderboard_time (pvp_leaderboard_id, snapshot_at DESC)
  # Dropping them frees index space on a 2.2M-row table and cuts write amplification.
  def up
    remove_index TABLE, name: CHAR_IDX,   algorithm: :concurrently, if_exists: true
    remove_index TABLE, name: LEADER_IDX, algorithm: :concurrently, if_exists: true
  end

  def down
    add_index TABLE, :character_id,       name: CHAR_IDX,   algorithm: :concurrently
    add_index TABLE, :pvp_leaderboard_id, name: LEADER_IDX, algorithm: :concurrently
  end
end
