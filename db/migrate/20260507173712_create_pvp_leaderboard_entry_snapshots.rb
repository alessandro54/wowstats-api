class CreatePvpLeaderboardEntrySnapshots < ActiveRecord::Migration[8.1]
  def up
    create_table :pvp_leaderboard_entry_snapshots do |t|
      t.references :character,         null: false, foreign_key: true
      t.references :pvp_leaderboard,   null: false, foreign_key: true
      t.references :pvp_sync_cycle,    null: true,  foreign_key: true
      t.datetime   :snapshot_at,       null: false
      t.integer    :rank,              null: false
      t.integer    :rating,            null: false
      t.integer    :wins,              null: false
      t.integer    :losses,            null: false
      t.integer    :spec_id
      t.timestamps
    end

    add_index :pvp_leaderboard_entry_snapshots,
              %i[character_id pvp_leaderboard_id snapshot_at],
              unique: true,
              name:   :idx_snap_unique

    add_index :pvp_leaderboard_entry_snapshots,
              %i[pvp_leaderboard_id snapshot_at],
              order: { snapshot_at: :desc },
              name:  :idx_snap_leaderboard_time

    add_index :pvp_leaderboard_entry_snapshots,
              %i[character_id snapshot_at],
              order: { snapshot_at: :desc },
              name:  :idx_snap_character_time

    # Day-0 backfill from current entries so the first post-deploy cycle
    # already has a baseline (saves ~6h of empty-state UX).
    execute <<~SQL
      INSERT INTO pvp_leaderboard_entry_snapshots
        (character_id, pvp_leaderboard_id, pvp_sync_cycle_id, snapshot_at,
         rank, rating, wins, losses, spec_id, created_at, updated_at)
      SELECT
        e.character_id, e.pvp_leaderboard_id, NULL, e.snapshot_at,
        e.rank, e.rating, e.wins, e.losses, e.spec_id, NOW(), NOW()
      FROM pvp_leaderboard_entries e
      ON CONFLICT (character_id, pvp_leaderboard_id, snapshot_at) DO NOTHING;
    SQL
  end

  def down
    drop_table :pvp_leaderboard_entry_snapshots
  end
end
