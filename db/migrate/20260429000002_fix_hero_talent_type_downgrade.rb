# Gateway hero talents (Halo, Void Torrent, etc.) appear under "class_talents"
# in the Blizzard character specialization endpoint even though they are hero
# talents. UpsertFromRawSpecializationService was calling update_all with
# talent_type: "class" on these blizzard_ids, overwriting the correct "hero"
# classification set by SyncTreeService.
#
# Two categories of affected talents:
#
# 1. Nodes where at least one variant is still correctly classified as "hero" but
#    sibling variants on the same node_id were downgraded to "class"/"spec".
#    Fixed by: restoring hero for all siblings sharing that node_id.
#
# 2. Fully-downgraded gateway nodes — every variant was downgraded to "class",
#    so there is no surviving "hero" sibling. These nodes are detected structurally:
#    a node qualifies when it has no hero variants left AND at least 8 of its 10
#    nearest node_id neighbours belong to hero talents. This signals a gateway node
#    sitting inside a hero-tree block — no hardcoded IDs needed.
#
# After this migration, UpsertFromRawSpecializationService has been patched with
# a `where.not(talent_type: "hero")` guard so this regression cannot recur.
class FixHeroTalentTypeDowngrade < ActiveRecord::Migration[8.0]
  def up
    # Pass 1: restore siblings whose node_id still has at least one hero variant.
    result1 = execute(<<~SQL)
      UPDATE talents
      SET talent_type = 'hero',
          updated_at  = NOW()
      WHERE node_id IN (
        SELECT DISTINCT node_id
        FROM talents
        WHERE talent_type = 'hero'
          AND node_id IS NOT NULL
      )
      AND talent_type != 'hero'
    SQL

    # Pass 2: restore fully-downgraded gateway nodes.
    # Detected structurally: node_ids where every talent lost its 'hero' type
    # AND >= 8 of the 10 surrounding node_ids belong to hero talents.
    result2 = execute(<<~SQL)
      WITH hero_node_ids AS (
        SELECT DISTINCT node_id FROM talents WHERE talent_type = 'hero' AND node_id IS NOT NULL
      ),
      fully_downgraded AS (
        SELECT node_id
        FROM talents
        WHERE node_id IS NOT NULL
        GROUP BY node_id
        HAVING COUNT(*) FILTER (WHERE talent_type = 'hero') = 0
           AND COUNT(*) FILTER (WHERE talent_type != 'pvp') > 0
      ),
      gateway_nodes AS (
        SELECT fd.node_id
        FROM fully_downgraded fd
        WHERE (
          SELECT COUNT(*)
          FROM hero_node_ids h
          WHERE h.node_id BETWEEN fd.node_id - 5 AND fd.node_id + 5
        ) >= 8
      )
      UPDATE talents
      SET talent_type = 'hero',
          updated_at  = NOW()
      FROM gateway_nodes
      WHERE talents.node_id = gateway_nodes.node_id
        AND talents.talent_type != 'hero'
    SQL

    total = result1.cmd_tuples + result2.cmd_tuples
    say "Restored hero classification for #{total} downgraded gateway talent(s) " \
        "(#{result1.cmd_tuples} via surviving sibling, #{result2.cmd_tuples} via structural gateway detection)"
  end

  def down
    # Not safely reversible — we don't know which were wrongly downgraded
  end
end
