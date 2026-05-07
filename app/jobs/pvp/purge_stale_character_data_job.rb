module Pvp
  class PurgeStaleCharacterDataJob < ApplicationJob
    queue_as :default

    BATCH_SIZE = 500

    def perform
      active_ids = PvpLeaderboardEntry.select(:character_id).distinct

      stale = Character.where.not(id: active_ids)
      total_purged = 0

      stale.in_batches(of: BATCH_SIZE) do |batch|
        char_ids = batch.pluck(:id)
        CharacterTalent.where(character_id: char_ids).delete_all
        CharacterItem.where(character_id: char_ids).delete_all
        Character.where(id: char_ids).delete_all
        total_purged += char_ids.size
      end

      Rails.logger.info("[PurgeStaleCharacterDataJob] Purged #{total_purged} stale characters")
    end
  end
end
