module Rag
  class EmbeddingService < BaseService
    MODEL = "text-embedding-3-small"
    MAX_INPUT_CHARS = 8_000

    def initialize(text)
      @text = text
    end

    def call
      return failure("Empty text") if @text.blank?

      response = client.embeddings(
        parameters: { model: MODEL, input: @text[0...MAX_INPUT_CHARS] }
      )
      vector = response.dig("data", 0, "embedding")
      return failure("No embedding returned") unless vector

      success(vector)
    rescue => e
      failure(e)
    end

    private

      def client
        @client ||= OpenAI::Client.new(access_token: ENV.fetch("OPENAI_API_KEY"))
      end
  end
end
