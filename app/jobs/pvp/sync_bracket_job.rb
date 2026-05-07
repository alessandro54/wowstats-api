module Pvp
  class SyncBracketJob < ApplicationJob
    queue_as :default

    # RateLimitedError inherits from Error but needs to be listed first,
    # so ActiveJob matches the more specific class.
    # The client already sleeps for Retry-After before raising, so a short wait suffices.
    retry_on Blizzard::Client::RateLimitedError, wait: 5, attempts: 5 do |_job, error|
      Rails.logger.warn("[SyncBracketJob] Rate limited, will retry: #{error.message}")
    end

    retry_on Blizzard::Client::Error, wait: :exponentially_longer, attempts: 3 do |_job, error|
      Rails.logger.warn("[SyncBracketJob] API error, will retry: #{error.message}")
    end

    # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
    def perform(region: "us", season:, bracket:, locale: "en_US")
      snapshot_at = Time.current

      result = Pvp::Leaderboards::SyncLeaderboardService.call(
        season:      season,
        bracket:     bracket,
        region:      region,
        locale:      locale,
        snapshot_at: snapshot_at
      )

      unless result.success?
        Rails.logger.error("[SyncBracketJob] #{region}/#{bracket} failed: #{result.error}")
        return
      end

      # Standalone use: enqueue character sync batches directly
      character_ids = result.context[:character_ids] || []

      # Filter out recently synced characters
      recently_synced_ids = PvpLeaderboardEntry
        .where(character_id: character_ids)
        .where("equipment_processed_at > ?", Pvp::SyncConfig::EQUIPMENT_TTL.ago)
        .distinct
        .pluck(:character_id)
        .to_set

      characters_to_sync = character_ids.reject { |id| recently_synced_ids.include?(id) }

      bracket_config = Pvp::BracketConfig.for(bracket)
      job_queue = bracket_config&.dig(:job_queue) || :character_sync

      batch_size = Pvp::SyncConfig::SYNC_BATCH_SIZE
      characters_to_sync.each_slice(batch_size) do |character_id_batch|
        Pvp::SyncCharacterBatchJob
          .set(queue: job_queue)
          .perform_later(
            character_ids: character_id_batch,
            locale:        locale
          )
      end
    end
    # rubocop:enable Metrics/MethodLength, Metrics/AbcSize
  end
end
