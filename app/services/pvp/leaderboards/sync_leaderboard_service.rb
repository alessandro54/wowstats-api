module Pvp
  module Leaderboards
    class SyncLeaderboardService < ApplicationService
      def initialize(season:, bracket:, region:, locale: "en_US", snapshot_at: Time.current, sync_cycle_id: nil)
        @season         = season
        @bracket        = bracket
        @region         = region
        @locale         = locale
        @snapshot_at    = snapshot_at
        @sync_cycle_id  = sync_cycle_id
      end

      # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
      def call
        res = Blizzard::Api::GameData::PvpSeason::Leaderboard.fetch(
          pvp_season_id: season.blizzard_id,
          bracket:       bracket,
          region:        region,
          locale:        locale
        )

        entries = res.fetch("entries", [])

        bracket_config = Pvp::BracketConfig.for(bracket)
        top_n = bracket_config&.dig(:top_n)

        # Take top N entries (already sorted by rank from API)
        entries = entries.first(top_n) if top_n

        character_ids = []

        # Upsert characters BEFORE acquiring the leaderboard lock so concurrent
        # bracket syncs (2v2 + 3v3 running in parallel) don't hold the row lock
        # while waiting on each other's character upserts.  Characters are
        # independent of the leaderboard row so no lock is needed here.
        character_records = entries.map do |entry_json|
          character_data  = entry_json.fetch("character")
          character_attrs = {
            blizzard_id: character_data["id"].to_s,
            region:      region,
            name:        character_data["name"],
            realm:       character_data.dig("realm", "slug")
          }

          if Character.new.respond_to?(:faction=)
            character_attrs[:faction] = faction_enum(entry_json.dig("faction", "type"))
          end

          character_attrs
        end

        unique_character_records = character_records
          .uniq { |c| [ c[:blizzard_id], c[:region] ] }
          .sort_by { |c| [ c[:blizzard_id], c[:region] ] }

        upsert_result = nil
        # rubocop:disable Rails/SkipsModelValidations
        with_deadlock_retry do
          upsert_result = Character.upsert_all(
            unique_character_records,
            unique_by: %i[blizzard_id region],
            returning: %i[blizzard_id id]
          )
        end
        # rubocop:enable Rails/SkipsModelValidations

        char_id_map = upsert_result.rows.to_h { |row| [ row[0].to_s, row[1] ] }

        entry_records = []
        leaderboard   = nil

        # rubocop:disable Metrics/BlockLength
        with_deadlock_retry do
          leaderboard = PvpLeaderboard.find_or_create_by!(
            pvp_season_id: season.id,
            bracket:       bracket,
            region:        region
          )

          bracket_spec_id = Wow::Catalog.spec_id_from_bracket(bracket)

          leaderboard.with_lock do
            now = Time.current
            built_records = entries.map do |entry_json|
              character_data = entry_json.fetch("character")
              stats          = entry_json.fetch("season_match_statistics")

              record = {
                pvp_leaderboard_id: leaderboard.id,
                character_id:       char_id_map[character_data["id"].to_s],
                rank:               entry_json["rank"],
                rating:             entry_json["rating"],
                wins:               stats["won"],
                losses:             stats["lost"],
                snapshot_at:        snapshot_at,
                created_at:         now,
                updated_at:         now
              }

              record[:spec_id] = bracket_spec_id if bracket_spec_id
              record
            end

            # Deduplicate by character_id — shuffle-overall leaderboards return the
            # same character once per spec ranking.  Keep the best placement (lowest rank).
            built_records = built_records
              .group_by { |r| r[:character_id] }
              .transform_values { |dupes| dupes.min_by { |r| r[:rank] } }
              .values

            ActiveRecord::Base.transaction do
              update_cols = %i[rank rating wins losses snapshot_at]
              update_cols.push(:spec_id) if bracket_spec_id

              # rubocop:disable Rails/SkipsModelValidations
              PvpLeaderboardEntry.upsert_all(
                built_records,
                unique_by:   %i[character_id pvp_leaderboard_id],
                update_only: update_cols
              )
              # rubocop:enable Rails/SkipsModelValidations

              character_ids = char_id_map.values
              leaderboard.update!(last_synced_at: snapshot_at)

              remove_dropped_entries(leaderboard.id, character_ids)
            end

            entry_records = built_records
          end
        end
        # rubocop:enable Metrics/BlockLength

        write_snapshots(entry_records, leaderboard)

        Rails.logger.info(
          "[SyncLeaderboardService] #{region}/#{bracket}: " \
          "#{entries.size} entries synced, #{character_ids.size} characters"
        )

        success(nil, context: { character_ids: character_ids, entry_count: entries.size })
      end
      # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

      private

        attr_reader :season, :bracket, :region, :locale, :snapshot_at, :sync_cycle_id

        def faction_enum(type)
          return nil unless type

          case type
          when "ALLIANCE" then 0
          when "HORDE"    then 1
          end
        end

        # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
        def write_snapshots(entry_records, leaderboard)
          return if entry_records.blank?

          rows = entry_records.map do |r|
            {
              character_id:       r[:character_id],
              pvp_leaderboard_id: r[:pvp_leaderboard_id],
              pvp_sync_cycle_id:  sync_cycle_id,
              snapshot_at:        snapshot_at,
              rank:               r[:rank],
              rating:             r[:rating],
              wins:               r[:wins],
              losses:             r[:losses],
              spec_id:            r[:spec_id],
              created_at:         Time.current,
              updated_at:         Time.current
            }
          end

          # rubocop:disable Rails/SkipsModelValidations
          inserted = PvpLeaderboardEntrySnapshot.insert_all(
            rows,
            unique_by: %i[character_id pvp_leaderboard_id snapshot_at],
            returning: [ :id ]
          )
          # rubocop:enable Rails/SkipsModelValidations
          count = inserted.rows.size
          Pvp::SyncLogger.snapshots_inserted(count: count, leaderboard: leaderboard)
        rescue => e
          Rails.logger.error("[SyncLeaderboardService] Snapshot insert failed: #{e.message}")
          Sentry.capture_exception(e, extra: {
            service:       "SyncLeaderboardService",
            region:        region,
            bracket:       bracket,
            snapshot_at:   snapshot_at,
            sync_cycle_id: sync_cycle_id
          })
        end
        # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

        # Delete entries for characters no longer present on the leaderboard.
        def remove_dropped_entries(leaderboard_id, active_character_ids)
          return if active_character_ids.empty?

          PvpLeaderboardEntry
            .where(pvp_leaderboard_id: leaderboard_id)
            .where.not(character_id: active_character_ids)
            .delete_all
        end
    end
  end
end
