module Blizzard
  module Api
    module Profile
      class BaseRequest < Blizzard::Api::BaseRequest
        def self.fetch_profile(region:, name:, realm:, locale: "en_US", params: {}, suffix: nil)
          c = client(region:, locale:)
          c.get(character_path(realm, name, suffix),
                namespace: c.profile_namespace,
                params:    params)
        end

        def self.fetch_profile_with_last_modified(region:, name:, realm:, locale: "en_US",
                                                  last_modified: nil, params: {}, suffix: nil)
          c = client(region:, locale:)
          c.get_with_last_modified(character_path(realm, name, suffix),
                                   namespace:     c.profile_namespace,
                                   params:        params,
                                   last_modified: last_modified)
        end

        def self.character_path(realm, name, suffix = nil)
          base = "/profile/wow/character/#{CGI.escape(realm.downcase)}/#{CGI.escape(name.downcase)}"
          suffix ? "#{base}/#{suffix}" : base
        end
      end
    end
  end
end
