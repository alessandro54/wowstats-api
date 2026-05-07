module Pvp
  module Meta
    class TalentSerializer
      def initialize(record_or_talent, locale:, prereqs:, default_points:)
        @rec = record_or_talent.respond_to?(:talent) ? record_or_talent : nil
        @talent = @rec ? @rec.talent : record_or_talent
        @locale = locale
        @prereqs = prereqs
        @default_points = default_points
      end

      def call
        @rec ? serialize_record : serialize_zero
      end

      private

        def serialize_record
          {
            id:             @rec.id,
            talent:         talent_fields(@talent.talent_type),
            usage_count:    @rec.usage_count,
            usage_pct:      @rec.usage_pct.to_f,
            in_top_build:   @rec.in_top_build,
            top_build_rank: @rec.top_build_rank,
            tier:           @rec.tier
          }
        end

        def serialize_zero
          dp = @default_points[@talent.id] || 0
          {
            id:             nil,
            talent:         talent_fields(@talent.talent_type),
            usage_count:    0,
            usage_pct:      0.0,
            in_top_build:   false,
            top_build_rank: 0,
            tier:           dp > 0 ? "bis" : "common"
          }
        end

        def talent_fields(talent_type)
          {
            id:                    @talent.id,
            blizzard_id:           @talent.blizzard_id,
            name:                  @talent.t("name", locale: @locale),
            talent_type:           talent_type,
            spell_id:              @talent.spell_id,
            node_id:               @talent.node_id,
            display_row:           @talent.display_row,
            display_col:           @talent.display_col,
            max_rank:              @talent.max_rank,
            icon_url:              @talent.icon_url,
            default_points:        @default_points[@talent.id] || 0,
            prerequisite_node_ids: @prereqs[@talent.node_id] || []
          }
        end
    end
  end
end
