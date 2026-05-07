module Pvp
  module Meta
    module ConfidenceScore
      module_function

      def for(total_players:, stale_count:)
        return "high"   if total_players >= 100 && stale_count.zero?
        return "medium" if total_players >= 30  && stale_count <= 5

        "low"
      end
    end
  end
end
