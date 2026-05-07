module Pvp
  module SyncConfig
    EQUIPMENT_TTL = 1.hour.freeze  # how long before an entry needs a fresh API fetch
    META_TTL      = 1.week.freeze  # how long before character metadata is considered stale

    # Per-batch concurrency (fibers/threads inside SyncCharacterBatchJob).
    SYNC_CONCURRENCY = ENV.fetch("PVP_SYNC_CONCURRENCY", 15).to_i

    # SolidQueue worker threads for character_sync queues. Must match
    # PVP_SYNC_THREADS in queue.yml so DB pool math is correct.
    SYNC_THREADS = ENV.fetch("PVP_SYNC_THREADS", 8).to_i

    # Characters per SyncCharacterBatchJob.
    SYNC_BATCH_SIZE = ENV.fetch("PVP_SYNC_BATCH_SIZE", 50).to_i

    # Parallel OS processes per region character_sync queue.
    CHARACTER_SYNC_PROCESSES = ENV.fetch("PVP_CHARACTER_SYNC_PROCESSES", 1).to_i

    # Concurrent leaderboard HTTP fetches in SyncCurrentSeasonLeaderboardsJob.
    LEADERBOARD_CONCURRENCY = ENV.fetch("PVP_LEADERBOARD_CONCURRENCY", 10).to_i

    # Top N characters per (bracket, spec) included in meta aggregations.
    META_TOP_N = ENV.fetch("PVP_META_TOP_N", 1000).to_i
  end
end
