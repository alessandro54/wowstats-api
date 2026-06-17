module Rag
  class RetrieveContextService < BaseService
    DEFAULT_LIMIT = 5

    def initialize(query:, limit: DEFAULT_LIMIT)
      @query = query
      @limit = limit
    end

    def call
      embed_result = Rag::EmbeddingService.call(@query)
      return embed_result if embed_result.failure?

      vector = embed_result.payload
      chunks = retrieve_knowledge_docs(vector) + retrieve_talent_descriptions(vector)

      success(chunks)
    end

    private

      def retrieve_knowledge_docs(vector)
        KnowledgeDocument
          .nearest_neighbors(:embedding, vector, distance: "cosine")
          .where.not(embedding: nil)
          .limit(@limit)
          .map { |doc| "[#{doc.title}]\n#{doc.content&.truncate(1_500)}" }
      end

      def retrieve_talent_descriptions(vector)
        Translation
          .talent_descriptions
          .nearest_neighbors(:embedding, vector, distance: "cosine")
          .where.not(embedding: nil)
          .limit(@limit)
          .map { |t| "[Talent: #{t.translatable_id}] #{t.value}" }
      end
  end
end
