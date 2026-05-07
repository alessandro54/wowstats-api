module Wow
  module Catalog
    SPECS = {
      62 => { spec_slug: "arcane",        class_id: 8,  class_slug: "mage",         role: :dps },
      63 => { spec_slug: "fire",          class_id: 8,  class_slug: "mage",         role: :dps },
      64 => { spec_slug: "frost",         class_id: 8,  class_slug: "mage",         role: :dps },

      65 => { spec_slug: "holy",       class_id: 2,  class_slug: "paladin",      role: :healer },
      66 => { spec_slug: "protection", class_id: 2,  class_slug: "paladin",      role: :tank },
      70 => { spec_slug: "retribution", class_id: 2, class_slug: "paladin", role: :dps },

      71 => { spec_slug: "arms",       class_id: 1,  class_slug: "warrior",      role: :dps },
      72 => { spec_slug: "fury",       class_id: 1,  class_slug: "warrior",      role: :dps },
      73 => { spec_slug: "protection", class_id: 1,  class_slug: "warrior",      role: :tank },

      102 => { spec_slug: "balance",     class_id: 11, class_slug: "druid",        role: :dps },
      103 => { spec_slug: "feral",       class_id: 11, class_slug: "druid",        role: :dps },
      104 => { spec_slug: "guardian",    class_id: 11, class_slug: "druid",        role: :tank },
      105 => { spec_slug: "restoration", class_id: 11, class_slug: "druid",        role: :healer },

      250 => { spec_slug: "blood",  class_id: 6, class_slug: "death_knight", role: :tank },
      251 => { spec_slug: "frost",  class_id: 6, class_slug: "death_knight", role: :dps },
      252 => { spec_slug: "unholy", class_id: 6, class_slug: "death_knight", role: :dps },

      253 => { spec_slug: "beast-mastery", class_id: 3, class_slug: "hunter",     role: :dps },
      254 => { spec_slug: "marksmanship",  class_id: 3, class_slug: "hunter",     role: :dps },
      255 => { spec_slug: "survival",      class_id: 3, class_slug: "hunter",     role: :dps },

      256 => { spec_slug: "discipline",  class_id: 5, class_slug: "priest",       role: :healer },
      257 => { spec_slug: "holy",        class_id: 5, class_slug: "priest",       role: :healer },
      258 => { spec_slug: "shadow",      class_id: 5, class_slug: "priest",       role: :dps },

      259 => { spec_slug: "assassination", class_id: 4, class_slug: "rogue",       role: :dps },
      260 => { spec_slug: "outlaw",        class_id: 4, class_slug: "rogue",       role: :dps },
      261 => { spec_slug: "subtlety",      class_id: 4, class_slug: "rogue",       role: :dps },

      262 => { spec_slug: "elemental",    class_id: 7, class_slug: "shaman",      role: :dps },
      263 => { spec_slug: "enhancement",  class_id: 7, class_slug: "shaman",      role: :dps },
      264 => { spec_slug: "restoration",  class_id: 7, class_slug: "shaman",      role: :healer },

      265 => { spec_slug: "affliction",  class_id: 9, class_slug: "warlock",     role: :dps },
      266 => { spec_slug: "demonology",  class_id: 9, class_slug: "warlock",     role: :dps },
      267 => { spec_slug: "destruction", class_id: 9, class_slug: "warlock",     role: :dps },

      268 => { spec_slug: "brewmaster",   class_id: 10, class_slug: "monk",         role: :tank },
      269 => { spec_slug: "windwalker",   class_id: 10, class_slug: "monk",         role: :dps },
      270 => { spec_slug: "mistweaver",   class_id: 10, class_slug: "monk",         role: :healer },

      577 => { spec_slug: "havoc", class_id: 12, class_slug: "demon_hunter", role: :dps },
      581 => { spec_slug: "vengeance", class_id: 12, class_slug: "demon_hunter", role: :tank },
      1480 => { spec_slug: "devourer", class_id: 12, class_slug: "demon_hunter", role: :dps },

      1467 => { spec_slug: "devastation",  class_id: 13, class_slug: "evoker",    role: :dps },
      1468 => { spec_slug: "preservation", class_id: 13, class_slug: "evoker",    role: :healer },
      1473 => { spec_slug: "augmentation", class_id: 13, class_slug: "evoker",    role: :dps }
    }.freeze

    CLASS_INDEX = SPECS.values
                       .uniq { |data| data[:class_id] }
                       .map { |data| [ data[:class_id], data[:class_slug] ] }
                       .to_h
                       .freeze

    def self.spec_slug(spec_id)
      key = normalize_spec_id(spec_id)
      return nil unless key

      SPECS[key]&.fetch(:spec_slug, nil)
    end

    def self.class_id_for_spec(spec_id)
      key = normalize_spec_id(spec_id)
      return nil unless key

      SPECS[key]&.fetch(:class_id, nil)
    end

    def self.class_slug_for_spec(spec_id)
      key = normalize_spec_id(spec_id)
      return nil unless key

      SPECS[key]&.fetch(:class_slug, nil)
    end

    def self.role_for_spec(spec_id)
      key = normalize_spec_id(spec_id)
      return nil unless key

      SPECS[key]&.fetch(:role, nil)
    end

    def self.class_slug(class_id)
      key = normalize_class_id(class_id)
      return nil unless key

      CLASS_INDEX[key]
    end

    def self.normalize_spec_id(spec_id)
      normalize_integer_id(spec_id)
    end

    def self.normalize_class_id(class_id)
      normalize_integer_id(class_id)
    end

    def self.normalize_integer_id(value)
      return nil if value.nil?
      return value if value.is_a?(Integer)

      str = value.to_s
      return nil unless str.match?(/\A\d+\z/)

      str.to_i
    end

    def self.all_specs_with_slugs
      SPECS.map { |id, data| data.merge(id: id) }
    end

    # Extracts spec_id from spec-specific bracket names like
    # "shuffle-rogue-assassination" or "blitz-warrior-arms".
    # Returns nil for non-spec brackets (2v2, 3v3, shuffle-overall, etc.).
    def self.spec_id_from_bracket(bracket)
      match = bracket&.match(/\A(?:shuffle|blitz)-(.+)-(.+)\z/)
      return nil unless match

      class_slug = match[1].to_s.tr("-", "_")
      spec_slug  = match[2].to_s

      SPECS.find { |_id, data|
        data[:class_slug] == class_slug && data[:spec_slug] == spec_slug
      }&.first
    end

    private_class_method :normalize_integer_id
  end
end
