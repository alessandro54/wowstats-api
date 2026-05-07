module Blizzard
  module Api
    module Profile
      class CharacterMediaSummary < BaseRequest
        def self.fetch(region:, name:, realm:, locale: "en_US", params: {})
          fetch_profile(region:, name:, realm:, locale:, params:, suffix: "character-media")
        end
      end
    end
  end
end
