# == Schema Information
#
# Table name: pvp_leaderboard_entry_snapshots
# Database name: primary
#
#  id                 :bigint           not null, primary key
#  losses             :integer          not null
#  rank               :integer          not null
#  rating             :integer          not null
#  snapshot_at        :datetime         not null
#  wins               :integer          not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  character_id       :bigint           not null
#  pvp_leaderboard_id :bigint           not null
#  pvp_sync_cycle_id  :bigint
#  spec_id            :integer
#
# Indexes
#
#  idx_snap_character_time                                     (character_id,snapshot_at DESC)
#  idx_snap_leaderboard_time                                   (pvp_leaderboard_id,snapshot_at DESC)
#  idx_snap_unique                                             (character_id,pvp_leaderboard_id,snapshot_at) UNIQUE
#  index_pvp_leaderboard_entry_snapshots_on_pvp_sync_cycle_id  (pvp_sync_cycle_id)
#
# Foreign Keys
#
#  fk_rails_...  (character_id => characters.id)
#  fk_rails_...  (pvp_leaderboard_id => pvp_leaderboards.id)
#  fk_rails_...  (pvp_sync_cycle_id => pvp_sync_cycles.id)
#
class PvpLeaderboardEntrySnapshot < ApplicationRecord
  belongs_to :character
  belongs_to :pvp_leaderboard
  belongs_to :pvp_sync_cycle, optional: true

  validates :snapshot_at, :rank, :rating, :wins, :losses, presence: true
end
