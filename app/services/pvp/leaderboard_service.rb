module Pvp
  # Mirror of Blizzard's bracket leaderboard: full ladder ordered by raw
  # `rank`, optional filters (region, spec_id, class_slug, name query),
  # paginated. Distinct from Pvp::Meta::TopPlayersService which scores
  # composite signals.
  class LeaderboardService < BaseService
    DEFAULT_REGIONS = %w[us eu].freeze
    MAX_PER_PAGE    = 500

    def initialize(season:, bracket:, spec_id: nil, class_slug: nil,
      regions: DEFAULT_REGIONS, page: 1, per_page: 50, query: nil,
      min_rating: nil, max_rating: nil, min_winrate: nil)
      @season      = season
      @bracket     = bracket
      @spec_id     = spec_id
      @class_slug  = class_slug
      @regions     = regions
      @page        = [ page.to_i, 1 ].max
      @per_page    = [ [ per_page.to_i, 1 ].max, MAX_PER_PAGE ].min
      @query       = query.to_s.strip.presence
      @min_rating  = min_rating&.to_i
      @max_rating  = max_rating&.to_i
      @min_winrate = min_winrate&.to_f
    end

    def call
      scope = filtered_scope
      total = scope.count
      rows  = paginated_rows(scope)
      success(envelope(total, rows))
    end

    private

      attr_reader :season, :bracket, :spec_id, :class_slug, :regions,
        :page, :per_page, :query, :min_rating, :max_rating, :min_winrate

      def filtered_scope
        apply_winrate(apply_rating(apply_identity(base_scope)))
      end

      def apply_identity(scope)
        scope = scope.where(pvp_leaderboard_entries: { spec_id: spec_id }) if spec_id
        scope = scope.where(characters: { class_slug: class_slug })        if class_slug
        scope = scope.where("characters.name ILIKE ?", "#{query}%")        if query
        scope
      end

      def apply_rating(scope)
        scope = scope.where("pvp_leaderboard_entries.rating >= ?", min_rating) if min_rating
        scope = scope.where("pvp_leaderboard_entries.rating <= ?", max_rating) if max_rating
        scope
      end

      def apply_winrate(scope)
        return scope unless min_winrate

        scope.where(
          "pvp_leaderboard_entries.wins + pvp_leaderboard_entries.losses > 0 AND " \
          "pvp_leaderboard_entries.wins::float / " \
          "NULLIF(pvp_leaderboard_entries.wins + pvp_leaderboard_entries.losses, 0) >= ?",
          min_winrate
        )
      end

      def base_scope
        PvpLeaderboardEntry
          .joins(:pvp_leaderboard, :character)
          .merge(PvpLeaderboard.where(pvp_season_id: season.id, region: regions).for_bracket(bracket))
          .where.not(rank: nil)
      end

      def paginated_rows(scope)
        scope
          .order(:rank)
          .limit(per_page)
          .offset((page - 1) * per_page)
          .select(*select_columns)
      end

      def envelope(total, rows)
        {
          bracket:     bracket,
          spec_id:     spec_id,
          class_slug:  class_slug,
          regions:     regions,
          query:       query,
          min_rating:  min_rating,
          max_rating:  max_rating,
          min_winrate: min_winrate,
          page:        page,
          per_page:    per_page,
          total:       total,
          total_pages: (total / per_page.to_f).ceil,
          players:     rows.map { |r| Pvp::Meta::TopPlayerSerializer.new(r).call },
          snapshot_at: rows.first&.snapshot_at
        }
      end

      def select_columns
        [
          "pvp_leaderboard_entries.rating",
          "pvp_leaderboard_entries.wins",
          "pvp_leaderboard_entries.losses",
          "pvp_leaderboard_entries.rank",
          "pvp_leaderboard_entries.spec_id",
          "pvp_leaderboard_entries.snapshot_at",
          "pvp_leaderboard_entries.rating AS score",
          "characters.name",
          "characters.realm",
          "characters.region",
          "characters.avatar_url",
          "characters.class_slug"
        ]
      end
  end
end
