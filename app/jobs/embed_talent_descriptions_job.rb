class EmbedTalentDescriptionsJob < ApplicationJob
  queue_as :default

  def perform
    Translation.talent_descriptions.needs_embedding.find_each do |t|
      result = Rag::EmbeddingService.call(t.value)
      if result.success?
        t.update_column(:embedding, result.payload) # rubocop:disable Rails/SkipsModelValidations
      else
        Rails.logger.warn("[EmbedTalentDescriptionsJob] Translation #{t.id} failed: #{result.error}")
      end
    end
  end
end
