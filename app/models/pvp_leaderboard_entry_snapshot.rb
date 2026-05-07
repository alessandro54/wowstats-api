class PvpLeaderboardEntrySnapshot < ApplicationRecord
  belongs_to :character
  belongs_to :pvp_leaderboard
  belongs_to :pvp_sync_cycle, optional: true

  validates :snapshot_at, :rank, :rating, :wins, :losses, presence: true
end
