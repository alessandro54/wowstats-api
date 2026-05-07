class Rack::Attack
  BLOCKED_PATHS = %w[
    .env
    .git
    .svn
    wp-admin
    wp-login
    wp-content
    wp-includes
    wp-json
    phpmyadmin
    phpMyAdmin
    xmlrpc.php
    administrator
    cgi-bin
  ].freeze

  BLOCKED_PATH_REGEX = Regexp.union(BLOCKED_PATHS.map { |p| /#{Regexp.escape(p)}/i })

  # Block scanner/probe requests
  blocklist("block_scanners") do |req|
    BLOCKED_PATH_REGEX.match?(req.path)
  end

  # Throttle all requests by IP: 120 req/min
  throttle("req/ip", limit: 120, period: 60) do |req|
    req.ip unless req.path == "/up"
  end

  # Return 403 for blocked requests
  self.blocklisted_responder = ->(env) {
    [ 403, { "content-type" => "text/plain" }, [ "Forbidden" ] ]
  }

  # Rack::Attack passes a Request object — use .env to reach the raw Rack env.
  self.throttled_responder = ->(req) {
    retry_after = (req.env["rack.attack.match_data"] || {})[:period]
    [ 429, { "content-type" => "text/plain", "retry-after" => retry_after.to_s }, [ "Rate limit exceeded" ] ]
  }

  # Use CF-Connecting-IP when behind Cloudflare, fall back to Rails' remote_ip
  # which filters trusted proxies. Never trust raw X-Forwarded-For directly
  # as it's trivially spoofable by clients not behind Cloudflare.
  class Request < ::Rack::Request
    def ip
      @ip ||= env["HTTP_CF_CONNECTING_IP"] || super
    end
  end
end
