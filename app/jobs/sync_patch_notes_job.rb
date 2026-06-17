class SyncPatchNotesJob < ApplicationJob
  queue_as :default

  def perform
    result = Blizzard::News::SyncPatchNotesService.call
    Rails.logger.warn("[SyncPatchNotesJob] #{result.error}") if result.failure?
  end
end
