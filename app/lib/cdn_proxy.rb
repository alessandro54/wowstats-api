module CdnProxy
  BLIZZARD_HOST = "render.worldofwarcraft.com"
  CDN_BASE      = "https://cdn.wowstats.gg/avatars"

  def self.rewrite(url)
    return nil unless url.present?

    uri = URI.parse(url)
    return url unless uri.host == BLIZZARD_HOST

    "#{CDN_BASE}#{uri.path}"
  rescue URI::InvalidURIError
    url
  end
end
