module Items
  class SyncItemMetaBatchJob < ApplicationJob
    queue_as :default

    CONCURRENCY = 10

    def perform(item_ids:)
      items = Item.where(id: item_ids).reject(&:meta_synced?)
      return if items.empty?

      Rails.logger.info("[Items::SyncItemMetaBatchJob] Syncing metadata for #{items.size} items")

      run_with_threads(items, concurrency: CONCURRENCY) do |item|
        sync_item(item)
      end
    end

    private

      def sync_item(item)
        return unless item.blizzard_id.present?

        response = Blizzard::Api::GameData::ItemMedia.fetch(blizzard_id: item.blizzard_id)
        icon_url = response.dig("assets")&.find { |a| a["key"] == "icon" }&.dig("value")
        return unless icon_url

        # rubocop:disable Rails/SkipsModelValidations
        item.update_columns(icon_url: icon_url, meta_synced_at: Time.current)
      rescue Blizzard::Client::NotFoundError
        # rubocop:enable Rails/SkipsModelValidations
      rescue Blizzard::Client::Error => e
        Rails.logger.warn("[Items::SyncItemMetaBatchJob] Failed for item #{item.id}: #{e.message}")
      end
  end
end
