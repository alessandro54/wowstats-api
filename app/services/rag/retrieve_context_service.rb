module Rag
  class RetrieveContextService < BaseService
    DEFAULT_LIMIT = 5
    TOP_TALENTS   = 8
    TOP_ITEMS     = 8

    # Candidate list size for the HNSW search. Higher = better recall, more work.
    # 40 is the pgvector default; bumped for our small tables where the cost is trivial.
    EF_SEARCH = 100

    def initialize(query:, spec_id:, bracket:, season:, limit: DEFAULT_LIMIT)
      @query   = query
      @spec_id = spec_id
      @bracket = bracket
      @season  = season
      @limit   = limit
    end

    def call
      embed_result = Rag::EmbeddingService.call(@query)
      return embed_result if embed_result.failure?

      vector = embed_result.payload
      chunks = ActiveRecord::Base.transaction do
        ActiveRecord::Base.connection.execute("SET LOCAL hnsw.ef_search = #{EF_SEARCH}")
        [
          strength_block,        # how strong: representation, win rate, rating, hero tree
          build_block,           # core vs situational vs alternate build
          meta_stats_block,      # top items
          top_talents_block,     # top talents (named, spec-filtered, usage %)
          *retrieve_knowledge_chunks(vector) # patch notes via vector search
        ].compact
      end

      success(chunks)
    end

    private

      # ----- vector retrieval (patch notes / news) -----

      def retrieve_knowledge_chunks(vector)
        KnowledgeDocumentChunk
          .nearest_neighbors(:embedding, vector, distance: "cosine")
          .where.not(embedding: nil)
          .includes(:knowledge_document)
          .limit(@limit)
          .map { |c| "[#{c.knowledge_document.title}]\n#{c.content}" }
      end

      # ----- strength signal (the "how strong" the model was missing) -----

      def ladder_scope
        @ladder_scope ||= PvpLeaderboardEntry
          .joins(:pvp_leaderboard)
          .where(pvp_leaderboards: { pvp_season_id: @season.id, bracket: @bracket })
          .where.not(specialization_processed_at: nil)
      end

      def strength_block
        return nil unless @season

        s = spec_stats
        return nil if s[:players].zero?

        rank, total = representation_rank
        lines = [ "  - Representation: #{s[:players]} players — #{rank} of #{total} specs by player count" ]
        lines << "  - Win rate: #{s[:win_rate]}% (#{s[:wins]}W / #{s[:losses]}L)" if s[:win_rate]
        lines << "  - Rating: avg #{s[:avg_rating]}, peak #{s[:top_rating]}"
        hero = hero_tree_line
        lines << hero if hero

        "Spec standing in #{@bracket} this season:\n#{lines.join("\n")}"
      end

      def representation_rank
        counts = ladder_scope.group(:spec_id).distinct.count(:character_id)
        rank = counts.sort_by { |_, c| -c }.index { |sid, _| sid == @spec_id }.to_i + 1
        [ rank, counts.size ]
      end

      # rubocop:disable Metrics/AbcSize
      def spec_stats
        scope = ladder_scope.where(spec_id: @spec_id)
        wins, losses, avg_rating, top_rating = scope.pluck(Arel.sql(<<~SQL.squish)).first
          COALESCE(SUM(wins), 0), COALESCE(SUM(losses), 0),
          COALESCE(ROUND(AVG(rating)), 0), COALESCE(MAX(rating), 0)
        SQL
        games = wins.to_i + losses.to_i
        {
          players:    scope.distinct.count(:character_id),
          wins:       wins.to_i,
          losses:     losses.to_i,
          win_rate:   games.positive? ? (100.0 * wins.to_i / games).round(1) : nil,
          avg_rating: avg_rating.to_i,
          top_rating: top_rating.to_i
        }
      end
      # rubocop:enable Metrics/AbcSize

      def hero_tree_line
        split = ladder_scope
          .where(spec_id: @spec_id)
          .where.not(hero_talent_tree_name: [ nil, "" ])
          .group(:hero_talent_tree_name)
          .count
        return nil if split.empty?

        total = split.values.sum.to_f
        parts = split.sort_by { |_, c| -c }.first(3).map { |name, c| "#{name} #{(100 * c / total).round}%" }
        "  - Hero tree: #{parts.join(', ')}"
      end

      # ----- build flexibility (situational + alternate builds) -----

      def build_block
        return nil unless @season

        rows = meta_talent_rows
        return nil if rows.empty?

        situational = rows.select { |r| r.tier == "situational" }
                          .map { |r| talent_name(r) }
        has_alt = rows.any? { |r| r.top_build_rank.to_i > 1 }

        lines = []
        lines << "  - Situational talents (swapped by matchup): #{situational.join(', ')}" if situational.any?
        lines << "  - A distinct secondary build exists alongside the primary one." if has_alt
        return nil if lines.empty?

        "Build flexibility:\n#{lines.join("\n")}"
      end

      # ----- meta blocks (talents + items) -----

      def meta_stats_block
        return nil unless @season

        items = PvpMetaItemPopularity
          .for_meta(season: @season, bracket: @bracket, spec_id: @spec_id)
          .limit(TOP_ITEMS)
          .map { |i|
            name = i.item.t("name", locale: "en_US") || "Item #{i.item_id}"
            "  - #{name} (#{i.slot}): #{i.usage_pct.to_f.round(1)}% usage"
          }

        return nil if items.empty?

        "Most-used items for this spec/bracket:\n#{items.join("\n")}"
      end

      def top_talents_block
        rows = meta_talent_rows.first(TOP_TALENTS)
        return nil if rows.empty?

        lines = rows.map do |r|
          desc = r.talent.t("description", locale: "en_US").to_s.gsub(/\s+/, " ").strip
          "[#{talent_name(r)} — #{r.usage_pct.to_f.round(1)}% usage] #{desc}"
        end

        "Most-used talents for this spec/bracket:\n#{lines.join("\n")}"
      end

      def meta_talent_rows
        @meta_talent_rows ||=
          PvpMetaTalentPopularity.for_meta(season: @season, bracket: @bracket, spec_id: @spec_id).to_a
      end

      def talent_name(row)
        row.talent.t("name", locale: "en_US") || "Talent #{row.talent_id}"
      end
  end
end
