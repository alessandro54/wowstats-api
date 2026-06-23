class AddTelegramMessageIdToPvpSyncCycles < ActiveRecord::Migration[8.1]
  def change
    add_column :pvp_sync_cycles, :telegram_message_id, :bigint
  end
end
