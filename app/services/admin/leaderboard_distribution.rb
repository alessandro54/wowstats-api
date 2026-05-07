module Admin
  class LeaderboardDistribution < BaseService
    CLASS_COLORS = {
      "warrior" => "#C79C6E",
      "paladin" => "#F58CBA",
      "hunter" => "#ABD473",
      "rogue" => "#FFF569",
      "priest" => "#D2D2D2",
      "death_knight" => "#C41F3B",
      "shaman" => "#0070DE",
      "mage" => "#69CCF0",
      "warlock" => "#9482C9",
      "monk" => "#00FF96",
      "druid" => "#FF7D0A",
      "demon_hunter" => "#A330C9",
      "evoker" => "#33937F"
    }.freeze

    REGULAR_ORDER = { "2v2" => 0, "3v3" => 1, "rbg" => 2, "blitz" => 3 }.freeze

    def initialize(season)
      @season = season
    end

    # rubocop:disable Metrics/AbcSize
    def call
      raw = PvpLeaderboardEntry
        .joins(:pvp_leaderboard)
        .where(pvp_leaderboards: { pvp_season: @season })
        .where.not(pvp_leaderboard_entries: { spec_id: nil })
        .group("pvp_leaderboards.bracket", "pvp_leaderboards.region", "pvp_leaderboard_entries.spec_id")
        .pluck(
          "pvp_leaderboards.bracket",
          "pvp_leaderboards.region",
          "pvp_leaderboard_entries.spec_id",
          Arel.sql("COUNT(*)")
        )

      nested = raw.each_with_object({}) do |(bracket, region, spec_id, count), acc|
        (acc[bracket] ||= {})[region] ||= {}
        acc[bracket][region][spec_id] = count
      end

      regular  = nested.reject { |b, _| b.start_with?("shuffle-") }
      shuffle  = nested.select { |b, _| b =~ /\Ashuffle-[^o]/ }

      { regular: build_regular(regular), shuffle: build_shuffle(shuffle) }
    end
    # rubocop:enable Metrics/AbcSize

    private

      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      def build_regular(brackets)
        brackets.map do |bracket, regions|
          spec_counts = {}
          regions.each do |region, specs|
            specs.each { |sid, count| (spec_counts[sid] ||= { us: 0, eu: 0 })[region.to_sym] += count }
          end

          total = spec_counts.values.sum { |v| v[:us] + v[:eu] }

          specs = spec_counts.map do |spec_id, counts|
            info  = Wow::Catalog::SPECS[spec_id] || {}
            combo = counts[:us] + counts[:eu]
            {
              spec_slug:  info[:spec_slug]  || "unknown",
              class_slug: info[:class_slug] || "unknown",
              role:       info[:role]       || :dps,
              color:      CLASS_COLORS.fetch(info[:class_slug].to_s, "#9ca3af"),
              us:         counts[:us],
              eu:         counts[:eu],
              total:      combo,
              pct:        total > 0 ? (combo.to_f / total * 100).round(1) : 0.0
            }
          end.sort_by { |s| -s[:total] }

          {
            bracket: bracket,
            regions: regions.keys.map(&:upcase).sort.join(" + "),
            total:   total,
            specs:   specs,
            sort:    REGULAR_ORDER.fetch(bracket, 10)
          }
        end.sort_by { |c| c[:sort] }
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      def build_shuffle(shuffle_brackets)
        class_data = {}

        shuffle_brackets.each do |bracket, regions|
          spec_id = Wow::Catalog.spec_id_from_bracket(bracket)
          next unless spec_id

          info = Wow::Catalog::SPECS[spec_id]
          next unless info

          us = regions.dig("us", spec_id).to_i
          eu = regions.dig("eu", spec_id).to_i

          (class_data[info[:class_slug]] ||= []) << {
            spec_id:   spec_id,
            spec_slug: info[:spec_slug],
            role:      info[:role] || :dps,
            color:     CLASS_COLORS.fetch(info[:class_slug], "#9ca3af"),
            us:        us,
            eu:        eu,
            total:     us + eu
          }
        end

        class_data
          .transform_values { |specs| specs.sort_by { |s| s[:spec_id] } }
          .sort_by { |cs, _| cs }
          .to_h
      end
    # rubocop:enable Metrics/AbcSize, Metrics/MethodLength
  end
end
