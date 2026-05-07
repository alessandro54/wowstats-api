module Pvp
  module BracketResolver
    AGGREGATES = {
      "blitz" => "blitz-%",
      "shuffle" => "shuffle-%"
    }.freeze

    module_function

    def aggregate?(slug)
      AGGREGATES.key?(slug)
    end

    def pattern_for(slug)
      AGGREGATES[slug]
    end

    def scope(relation, slug, column: "bracket")
      pattern = pattern_for(slug)
      pattern ? relation.where("#{column} LIKE ?", pattern) : relation.where(column => slug)
    end
  end
end
