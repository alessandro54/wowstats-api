require "httpx"
require "uri"
require "oj"

module Blizzard
  class Auth
    class Error < StandardError; end

    OAUTH_URL           = "https://oauth.battle.net/oauth/token".freeze
    CACHE_KEY_PREFIX    = "blizzard_access_token".freeze
    EXPIRY_SKEW_SECONDS = 60

    # In-process token cache — avoids a Rails.cache (SolidCache/DB) round-trip on
    # every API request. Keyed by client_id so multiple credentials don't share
    # the same slot and overwrite each other's tokens.
    PROCESS_TOKEN_MUTEX = Mutex.new
    @process_tokens     = {}
    @process_expires_at = {}

    def self.cache_key_for(client_id)
      "#{CACHE_KEY_PREFIX}:#{client_id}"
    end

    def self.in_process_token(client_id)
      PROCESS_TOKEN_MUTEX.synchronize do
        t   = @process_tokens[client_id]
        exp = @process_expires_at[client_id]
        return t if t.present? && exp && exp > Time.current

        nil
      end
    end

    def self.store_in_process(client_id, token, expires_at)
      PROCESS_TOKEN_MUTEX.synchronize do
        @process_tokens[client_id]     = token
        @process_expires_at[client_id] = expires_at
      end
    end

    # Used in tests to prevent token leaking across examples.
    def self.reset_in_process_cache!
      PROCESS_TOKEN_MUTEX.synchronize do
        @process_tokens     = {}
        @process_expires_at = {}
      end
    end

    def self.invalidate_in_process!(client_id)
      PROCESS_TOKEN_MUTEX.synchronize do
        @process_tokens.delete(client_id)
        @process_expires_at.delete(client_id)
      end
    end

    # Clears both caches so the next access_token call fetches a fresh token.
    # Called by the API client when Blizzard returns 401 Unauthorized.
    def invalidate!
      self.class.invalidate_in_process!(@client_id)
      Rails.cache&.delete(self.class.cache_key_for(@client_id))
    end

    attr_reader :client_id

    def initialize(
      client_id: Rails.application.credentials.dig(:blizzard, :client_id) || ENV["BLIZZARD_CLIENT_ID"],
      client_secret: Rails.application.credentials.dig(:blizzard, :client_secret) || ENV["BLIZZARD_CLIENT_SECRET"]
    )
      @client_id = client_id
      @client_secret = client_secret

      return unless @client_id.blank? || @client_secret.blank?

      raise ArgumentError,
            "Blizzard client_id and client_secret must be provided. " \
            "Set Rails credentials (blizzard.client_id / blizzard.client_secret) " \
            "or ENV BLIZZARD_CLIENT_ID / BLIZZARD_CLIENT_SECRET. " \
            "If using credentials in a worker process, ensure RAILS_MASTER_KEY is present."
    end

    def access_token
      # 1. In-process memory — no DB query at all (fastest path)
      in_process = self.class.in_process_token(@client_id)
      return in_process if in_process

      # 2. Shared Rails.cache — another worker process may have refreshed the token
      cached = read_cache
      if cached.present? && cached[:token].present? &&
         cached[:expires_at].present? && cached[:expires_at] > Time.current
        self.class.store_in_process(@client_id, cached[:token], cached[:expires_at])
        return cached[:token]
      end

      # 3. Fetch fresh token from Blizzard OAuth
      fetch_and_cache_access_token!
    end

    private

      def fetch_and_cache_access_token!
        response = perform_oauth_request
        body     = parse_response_body(response)

        token, expires_in = extract_token_data(body)
        expires_at = compute_expires_at(expires_in)

        write_cache(token, expires_at, expires_in)
        self.class.store_in_process(@client_id, token, expires_at)
        token
      end

      def perform_oauth_request
        response = HTTPX.with(timeout: { request_timeout: 30 }).post(
          OAUTH_URL,
          form:    { grant_type: "client_credentials" },
          headers: {
            "Authorization": "Basic #{Base64.strict_encode64("#{@client_id}:#{@client_secret}")}"
          }
        )

        if response.is_a?(HTTPX::ErrorResponse)
          raise Error, "Blizzard OAuth error: network/transport error: #{response.error}"
        end

        return response if response.status == 200

        raise Error, "Blizzard OAuth error: HTTP #{response.status}"
      end

      def parse_response_body(response)
        # Use Oj directly for ~2-3x faster JSON parsing
        Oj.load(response.body, mode: :compat)
      rescue Oj::ParseError, JSON::ParserError
        raise Error, "Blizzard OAuth error: invalid JSON response\n#{response.body}"
      end

      def extract_token_data(body)
        token      = body["access_token"]
        expires_in = body["expires_in"].to_i

        if token.blank? || expires_in.zero?
          raise Error, "Blizzard OAuth error: response does not include access_token.\n#{body.inspect}"
        end

        [ token, expires_in ]
      end

      def compute_expires_at(expires_in)
        Time.current + expires_in - EXPIRY_SKEW_SECONDS
      end

      def read_cache
        Rails.cache&.read(self.class.cache_key_for(@client_id))
      end

      def write_cache(token, expires_at, expires_in)
        cache = Rails.cache

        unless cache
          Rails.logger.warn("[Blizzard::Auth] Rails.cache is nil; skipping access token caching")
          return
        end

        cache.write(
          self.class.cache_key_for(@client_id),
          { token: token, expires_at: expires_at },
          expires_in: expires_in
        )
      end
  end
end
