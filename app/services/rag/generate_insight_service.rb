module Rag
  class GenerateInsightService < BaseService
    SYSTEM_PROMPT = <<~PROMPT.freeze
      You are a World of Warcraft PvP analyst writing a short briefing on one spec in one bracket.

      You are given structured data (representation, win rate, rating, hero-tree split, build
      flexibility, top talents and items) and relevant patch-note passages. Write 3-4 tight
      paragraphs:

      1. OPEN WITH A VERDICT. One sentence stating how the spec is actually doing, led by the hard
         numbers (representation rank, win rate, rating). This is the headline — not a kit tour.
      2. WHY. Two or three synthesized reasons for that standing — recent patch changes, how its
         kit fits the current meta, what the build choices reveal. Group abilities by what they
         accomplish (survivability, control, pressure); do NOT walk through talents one by one or
         restate ability tooltips.
      3. BUILD & FLEX. What the hero-tree split and any situational/alternate builds tell us.
      4. MATCHUPS. A brief, clearly-analytical read of what it beats and struggles against, framed
         as reasoning from its kit — never as measured win-rate data (we have no matchup data).

      Rules: cite the provided numbers exactly; never invent stats. If the patch notes contain no
      changes for this spec, say so plainly rather than implying buffs. Be specific, not generic.
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
