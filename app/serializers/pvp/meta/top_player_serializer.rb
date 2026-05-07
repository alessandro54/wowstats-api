module Pvp
  module Meta
    class TopPlayerSerializer
      def initialize(row)
        @row = row
      end

      def call
        {
          name:       @row.name,
          realm:      format_realm(@row.realm),
          region:     format_region(@row.region),
          rating:     @row.rating,
          wins:       @row.wins,
          losses:     @row.losses,
          rank:       @row.rank,
          score:      @row.score.to_f,
          avatar_url: CdnProxy.rewrite(@row.avatar_url),
          class_slug: format_class_slug(@row.class_slug),
          spec_id:    spec_id_for(@row)
        }
      end

      private

        def format_realm(realm)
          realm.to_s.tr("-", " ").titleize
        end

        def format_region(region)
          region.to_s.upcase
        end

        def format_class_slug(slug)
          slug.to_s.tr("_", "-").presence
        end

        def spec_id_for(row)
          row.respond_to?(:spec_id) ? row.spec_id : nil
        end
    end
  end
end
