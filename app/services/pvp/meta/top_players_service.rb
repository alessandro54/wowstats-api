module Pvp
  module Meta
    # Composite ranking for a bracket+spec leaderboard:
    #   rating + winrate_bonus(≥60% only) - grinder_penalty(<60% over many games)
    # Falls back to unfiltered base when MIN_GAMES gate yields fewer than LIMIT.
    class TopPlayersService < BaseService
      DEFAULT_REGIONS        = %w[us eu].freeze
      LIMIT                  = 10
      MIN_GAMES              = 50
      GRINDER_GAME_THRESHOLD = 200

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

      def initialize(season:, bracket:, spec_id:, regions: DEFAULT_REGIONS)
        @season  = season
        @bracket = bracket
        @spec_id = spec_id
        @regions = regions
      end

      def call
        rows = query_top_players
        success({
          bracket:     bracket,
          spec_id:     spec_id,
          regions:     regions,
          players:     rows.map { |r| TopPlayerSerializer.new(r).call },
          snapshot_at: rows.first&.snapshot_at
        })
      end

      private

        attr_reader :season, :bracket, :spec_id, :regions

        def query_top_players
          base   = player_base_query
          scored = base.where("pvp_leaderboard_entries.wins + pvp_leaderboard_entries.losses >= ?", MIN_GAMES)
          scored.size >= LIMIT ? scored : base
        end

        def player_base_query
          PvpLeaderboardEntry
            .joins(:pvp_leaderboard, :character)
            .where(
              pvp_leaderboards:        { pvp_season_id: season.id, bracket: bracket, region: regions },
              pvp_leaderboard_entries: { spec_id: spec_id }
            )
            .where.not(equipment_processed_at: nil)
            .where("pvp_leaderboard_entries.equipment_processed_at >= ?", 60.days.ago)
            .order(Arel.sql("(#{SCORE_SQL}) DESC"))
            .limit(LIMIT)
            .select(*select_columns)
        end

        def select_columns
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
    end
  end
end
