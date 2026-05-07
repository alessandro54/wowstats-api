# frozen_string_literal: true

module Pvp
  class LeaderboardEntrySerializer
    def initialize(entry, delta: nil)
      @entry = entry
      @delta = delta
    end

    def call
      {
        character_id: entry.character_id,
        rank:         entry.rank,
        rating:       entry.rating,
        wins:         entry.wins,
        losses:       entry.losses,
        spec_id:      entry.spec_id,
        snapshot_at:  entry.snapshot_at,
        delta:        delta_payload
      }
    end

    private

      attr_reader :entry, :delta

      def delta_payload
        return nil if delta.nil?

        build_delta
      end

      def build_delta
        {
          rank:   entry.rank   - delta[:rank],
          rating: entry.rating - delta[:rating],
          wins:   entry.wins   - delta[:wins],
          losses: entry.losses - delta[:losses]
        }
      end
  end
end
