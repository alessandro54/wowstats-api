module Rag
  class GenerateInsightService < BaseService
    SYSTEM_PROMPT = <<~PROMPT.freeze
      You are a World of Warcraft PvP analyst. Given current meta data and relevant patch notes or
      ability descriptions, explain in 2-4 concise paragraphs why the given spec is performing the
      way it is. Focus on recent changes, key abilities, and synergies. Be specific and factual.
      Do not speculate beyond the provided context.
    PROMPT

    def initialize(spec_name:, bracket:, context_chunks:)
      @spec_name      = spec_name
      @bracket        = bracket
      @context_chunks = context_chunks
    end

    def call
      return failure("No context available") if @context_chunks.empty?

      user_message = build_user_message
      response = client.messages(
        parameters: {
          model:      ENV.fetch("ANTHROPIC_MODEL", "claude-opus-4-8"),
          system:     SYSTEM_PROMPT,
          messages:   [ { role: "user", content: user_message } ],
          max_tokens: 1024
        }
      )
      text = response.dig("content", 0, "text")
      return failure("Empty response from Claude") if text.blank?

      success(text)
    rescue => e
      failure(e)
    end

    private

      def build_user_message
        context = @context_chunks.join("\n\n---\n\n")
        <<~MSG
          Spec: #{@spec_name}
          Bracket: #{@bracket}

          Relevant context from patch notes and ability descriptions:
          #{context}

          Please explain why #{@spec_name} is performing the way it is in #{@bracket} PvP.
        MSG
      end

      def client
        @client ||= Anthropic::Client.new(access_token: ENV.fetch("ANTHROPIC_API_KEY"))
      end
  end
end
