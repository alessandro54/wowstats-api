module Pvp
  class PruneLeaderboardSnapshotsJob < ApplicationJob
    queue_as :default

    RETENTION  = 7.days
    BATCH_SIZE = 10_000

    def perform
      cutoff = RETENTION.ago
      total  = 0

      loop do
        n = PvpLeaderboardEntrySnapshot
          .where("snapshot_at < ?", cutoff)
          .limit(BATCH_SIZE)
          .delete_all
        total += n
        break if n.zero?
      end

      Rails.logger.info("[PruneLeaderboardSnapshotsJob] Deleted #{total} rows older than #{cutoff}")
    end
  end
end
