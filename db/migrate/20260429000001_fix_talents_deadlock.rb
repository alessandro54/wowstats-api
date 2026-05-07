# Removes the composite index on (talent_type, blizzard_id) from the talents
# table. This index doubles the number of index tuples Postgres must ShareLock
# per concurrent INSERT, which is the direct cause of the deadlocks seen in
# Blizzard::Data::Talents::UpsertFromRawSpecializationService.
#
# The unique index on blizzard_id alone is sufficient for insert_all conflict
# detection. The talent_type column is corrected post-insert via update_all,
# which only touches rows that actually differ and does not create index lock
# contention.
#
# Queries that filter on talent_type can use the unique blizzard_id index
# combined with a heap filter — the table is small enough that this is fast.
class FixTalentsDeadlock < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    remove_index :talents,
                 name: "index_talents_on_talent_type_and_blizzard_id",
                 algorithm: :concurrently,
                 if_exists: true
  end

  def down
    add_index :talents,
              %i[talent_type blizzard_id],
              name: "index_talents_on_talent_type_and_blizzard_id",
              algorithm: :concurrently,
              if_exists: false
  end
end
