class Api::V1::Pvp::Meta::TopPlayersController < Api::V1::BaseController
  DEFAULT_REGIONS  = %w[us eu].freeze
  LIMIT            = 10
  MIN_GAMES              = 50
  GRINDER_GAME_THRESHOLD = 200

  # Composite score:
  #   rating
  #   + winrate_bonus    (up to +120 for ≥80% winrate, 0 at 60%)
  #   - grinder_penalty  (up to -300 for sub-60% winrate with many games)
  #
  # Winrate bonus: rewards players ABOVE 60% winrate.
  #   60% = neutral, 70% = +60, 80% = +120.
  #
  # Grinder penalty: scales with (a) how far below 60% winrate, and
  #   (b) how many games beyond GRINDER_GAME_THRESHOLD. Factor caps at 1.5×
  #   so deep grinders (400+ games) get up to 50% extra penalty.
  #   57% with 532 games → penalty ≈ -36 pts.
  #   52% with 400 games → penalty ≈ -64 pts.
  #   A 150-game player below threshold gets no penalty.
  SCORE_SQL = Arel.sql(<<~SQL.squish)
    pvp_leaderboard_entries.rating
    + LEAST(120, GREATEST(0,
        (pvp_leaderboard_entries.wins * 100.0
          / NULLIF(pvp_leaderboard_entries.wins + pvp_leaderboard_entries.losses, 0)
        - 60) * 6.0
      ))
    - LEAST(300, GREATEST(0,
        (60 - pvp_leaderboard_entries.wins * 100.0
          / NULLIF(pvp_leaderboard_entries.wins + pvp_leaderboard_entries.losses, 0)
        ) * 8.0
        * LEAST(1.5, GREATEST(0,
            (pvp_leaderboard_entries.wins + pvp_leaderboard_entries.losses - #{GRINDER_GAME_THRESHOLD})::float
            / #{GRINDER_GAME_THRESHOLD}
          ))
      ))
  SQL

  # GET /api/v1/pvp/meta/top_players
  # Returns top 10 players for a given bracket + spec.
  # When no region is given, merges US and EU results.
  # Only includes players whose equipment was processed for this spec within
  # the current season window — once a player switches specs,
  # equipment_processed_at stops being refreshed for their old-spec entry.
  include MetaParams

  def index
    regions   = region_params
    cache_key = meta_cache_key("top_players", bracket_param, spec_id_param, regions.join("+"))

    json = meta_cache_fetch(cache_key) do
      rows = query_top_players(regions)

      {
        bracket:     bracket_param,
        spec_id:     spec_id_param,
        regions:     regions,
        players:     serialize_players(rows),
        snapshot_at: rows.first&.snapshot_at
      }
    end

    render json: json
    set_cache_headers
  end

  private

    def region_params
      @region_params ||= if params[:region].present?
        Array(params[:region]).select { |r| validate_region(r) }
      else
        DEFAULT_REGIONS
      end
    end

    def query_top_players(regions)
      base   = player_base_query(regions)
      scored = base.where("pvp_leaderboard_entries.wins + pvp_leaderboard_entries.losses >= ?", MIN_GAMES)
      scored.size >= LIMIT ? scored : base
    end

    def player_base_query(regions)
      PvpLeaderboardEntry
        .joins(:pvp_leaderboard, :character)
        .where(
          pvp_leaderboards:        { pvp_season_id: current_season.id, bracket: bracket_param, region: regions },
          pvp_leaderboard_entries: { spec_id: spec_id_param }
        )
        .where.not(equipment_processed_at: nil)
        .where("pvp_leaderboard_entries.equipment_processed_at >= ?", 60.days.ago)
        .order(Arel.sql("(#{SCORE_SQL}) DESC"))
        .limit(LIMIT)
        .select(*player_select_columns)
    end

    def player_select_columns
      [
        "pvp_leaderboard_entries.rating",
        "pvp_leaderboard_entries.wins",
        "pvp_leaderboard_entries.losses",
        "pvp_leaderboard_entries.rank",
        "pvp_leaderboard_entries.snapshot_at",
        "ROUND((#{SCORE_SQL})::numeric, 1) AS score",
        "characters.name",
        "characters.realm",
        "characters.region",
        "characters.avatar_url",
        "characters.class_slug"
      ]
    end

    def serialize_players(rows)
      rows.map do |row|
        {
          name:       row.name,
          realm:      format_realm(row.realm),
          region:     format_region(row.region),
          rating:     row.rating,
          wins:       row.wins,
          losses:     row.losses,
          rank:       row.rank,
          score:      row.score.to_f,
          avatar_url: row.avatar_url,
          class_slug: row.class_slug
        }
      end
    end

    def format_realm(realm)
      realm.to_s.tr("-", " ").titleize
    end

    def format_region(region)
      region.to_s.upcase
    end
end
