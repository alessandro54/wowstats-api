class EmbedKnowledgeDocumentsJob < ApplicationJob
  queue_as :default

  # Split any unchunked documents into windows, then embed every chunk that
  # still lacks an embedding. Splitting and embedding are separate passes so a
  # re-fetched document (chunks rebuilt) gets re-embedded on the next run.
  def perform
    KnowledgeDocument.needs_chunking.find_each(&:rebuild_chunks!)

    KnowledgeDocumentChunk.needs_embedding.find_each do |chunk|
      result = Rag::EmbeddingService.call(chunk.content)
      if result.success?
        chunk.update_column(:embedding, result.payload) # rubocop:disable Rails/SkipsModelValidations
      else
        Rails.logger.warn("[EmbedKnowledgeDocumentsJob] Chunk #{chunk.id} failed: #{result.error}")
      end
    end
  end
end
