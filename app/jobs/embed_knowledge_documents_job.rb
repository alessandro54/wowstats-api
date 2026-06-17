class EmbedKnowledgeDocumentsJob < ApplicationJob
  queue_as :default

  def perform
    KnowledgeDocument.needs_embedding.find_each do |doc|
      result = Rag::EmbeddingService.call(doc.content)
      if result.success?
        doc.update_column(:embedding, result.payload) # rubocop:disable Rails/SkipsModelValidations
      else
        Rails.logger.warn("[EmbedKnowledgeDocumentsJob] Doc #{doc.id} failed: #{result.error}")
      end
    end
  end
end
