module Blizzard
  module Api
    module Profile
      class CharacterSpecializationSummary < BaseRequest
        def self.fetch(region:, name:, realm:, locale: "en_US", params: {})
          fetch_profile(region:, name:, realm:, locale:, params:, suffix: "specializations")
        end

        # Returns [body_or_nil, last_modified, changed] — see Client#get_with_last_modified.
        def self.fetch_with_last_modified(region:, name:, realm:, locale: "en_US", last_modified: nil, params: {})
          fetch_profile_with_last_modified(
            region:, name:, realm:, locale:, last_modified:, params:, suffix: "specializations"
          )
        end
      end
    end
  end
end
