module Blizzard
  module Api
    module Profile
      class CharacterProfileSummary < BaseRequest
        def self.fetch(region:, name:, realm:, locale: "en_US", params: {})
          fetch_profile(region:, name:, realm:, locale:, params:)
        end
      end
    end
  end
end
