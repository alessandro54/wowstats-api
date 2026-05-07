# app/services/blizzard/client.rb

module Blizzard
  class Client
    class Error < StandardError; end
    class NotFoundError < Error; end
    class RateLimitedError < Error; end
    class UnauthorizedError < Error; end

    # Shared HTTP client instance with connection pooling
    # Thread-safe: HTTPX handles concurrent requests internally
    HTTP_CLIENT = HTTPX
      .plugin(:persistent)
      .plugin(:retries, retry_on: ->(res) { res.is_a?(HTTPX::ErrorResponse) }, max_retries: 2)
      .with(
        timeout: {
          connect_timeout:   5,
          operation_timeout: 15
        }
      )

    # Rate limiting strategy:
    # - Per-job concurrency is bounded by run_concurrently's Async::Semaphore
    #   (default 5 fibers via PVP_SYNC_CONCURRENCY)
    # - 429 responses trigger sleep(Retry-After) + RateLimitedError
    # - Blizzard allows 100 req/s; with persistent connections and bounded
    #   concurrency, throughput is naturally limited by API latency (~300ms)
    #   giving ~5-10 chars/s per job which stays well under the limit.

    attr_reader :region, :locale, :auth

    API_HOST_TEMPLATE = "%{region}.api.blizzard.com".freeze

    VALID_REGIONS = %w[us eu kr tw].freeze

    VALID_LOCALES = {
      "us" => %w[en_US es_MX pt_BR],
      "eu" => %w[en_GB es_ES fr_FR de_DE it_IT ru_RU],
      "kr" => %w[ko_KR],
      "tw" => %w[zh_TW]
    }.stringify_keys!.freeze
    DEFAULT_LOCALE = "en_US".freeze

    def self.default_locale_for(region)
      VALID_LOCALES.fetch(region.to_s, VALID_LOCALES["us"]).first
    end

    def initialize(region: "us", locale: DEFAULT_LOCALE, auth: Blizzard::AuthPool.next_auth)
      raise ArgumentError, "Unsupported Blizzard API region: #{region}" unless VALID_REGIONS.include?(region)

      allowed_locales = VALID_LOCALES.fetch(region)

      unless allowed_locales.include?(locale)
        raise ArgumentError, "Invalid locale '#{locale}' for region '#{region}'"
      end

      @region = region
      @locale = locale
      @auth = auth
    end

    def get(path, namespace:, params: {})
      perform_request(path, namespace: namespace, params: params) do |response|
        parse_response(response)
      end
    end

    # Last-Modified-aware GET. Sends If-Modified-Since when a previous value is present.
    # Blizzard profile endpoints return Last-Modified but not ETag.
    # Returns [body, last_modified, changed]:
    #   changed = true  → 200 OK, body contains parsed JSON, last_modified is new value
    #   changed = false → 304 Not Modified, body is nil, last_modified is the original
    def get_with_last_modified(path, namespace:, params: {}, last_modified: nil)
      extra_headers = last_modified.present? ? { "If-Modified-Since": last_modified } : {}

      perform_request(path, namespace: namespace, params: params, extra_headers: extra_headers) do |response|
        parse_last_modified_response(response, last_modified)
      end
    end

    def profile_namespace = "profile-#{region}"
    def dynamic_namespace = "dynamic-#{region}"
    def static_namespace = "static-#{region}"

    private

      # Shared rate-limit + retry wrapper used by both #get and #get_with_etag.
      # Yields the raw HTTPX response to the caller's block, which is responsible
      # for parsing and raising RateLimitedError on 429.
      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      def perform_request(path, namespace:, params: {}, extra_headers: {})
        attempts = 0

        begin
          attempts += 1
          rate_limiter.acquire

          response = HTTP_CLIENT.get(
            build_url(path),
            params:  { namespace: namespace, locale: locale }.merge(params),
            headers: auth_header.merge(extra_headers)
          )

          raise UnauthorizedError if response.status == 401

          yield response
        rescue UnauthorizedError
          # Token expired or revoked mid-flight. Invalidate both caches so the
          # next auth_header call fetches a fresh token, then retry once.
          raise if attempts >= 2

          Rails.logger.warn("[Blizzard::Client] 401 on #{region}, invalidating token and retrying")
          auth.invalidate!
          retry
        rescue RateLimitedError => e
          # Retry once after sleeping the Retry-After period.
          # A second consecutive 429 means something is wrong — propagate.
          raise if attempts >= 2

          retry_after = e.message[/Retry-After: (\d+)s/, 1]&.to_i || 5
          Rails.logger.warn("[Blizzard::Client] 429 on #{region}, sleeping #{retry_after}s before retry")
          # Drain the shared bucket so every other thread in this process also
          # backs off — prevents multiple threads hammering the same region
          # simultaneously after one 429 slips through.
          rate_limiter.penalize!(drain_seconds: retry_after.to_f)
          sleep(retry_after)
          retry
        end
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      # Parses a response for Last-Modified-aware requests.
      # Returns [body_or_nil, last_modified, changed].
      # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
      def parse_last_modified_response(response, original_last_modified)
        if response.is_a?(HTTPX::ErrorResponse)
          raise Error, "Network/Transport error: #{response.error}"
        end

        case response.status
        when 304
          [ nil, original_last_modified, false ]
        when 200
          body = Oj.load(response.body.to_s, mode: :compat)
          [ body, response.headers["last-modified"], true ]
        when 404
          raise NotFoundError,
                "Blizzard API error: HTTP 404, body=#{response.body}"
        when 429
          retry_after = response.headers["retry-after"]&.to_i || 1
          raise RateLimitedError,
                "Blizzard API rate limited (429). Retry-After: #{retry_after}s"
        else
          raise Error,
                "Blizzard API error: HTTP #{response.status}, body=#{response.body}"
        end
      rescue Oj::ParseError, JSON::ParserError => e
        raise Error,
              "Blizzard API error: invalid JSON: #{e.message}\n#{response.body}"
      end
      # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

      def rate_limiter
        RateLimiter.for_credential("#{auth.client_id}:#{region}")
      end

      def build_url(path)
        "https://#{API_HOST_TEMPLATE % { region: region }}#{path}"
      end

      def auth_header
        { Authorization: "Bearer #{auth.access_token}" }
      end

      # rubocop:disable Metrics/AbcSize
      def parse_response(response)
        if response.is_a?(HTTPX::ErrorResponse)
          raise Error, "Network/Transport error: #{response.error}"
        end

        if response.status == 200
          return Oj.load(response.body.to_s, mode: :compat)
        end

        if response.status == 404
          raise NotFoundError,
                "Blizzard API error: HTTP 404, body=#{response.body}"
        end

        if response.status == 429
          retry_after = response.headers["retry-after"]&.to_i || 1
          raise RateLimitedError,
                "Blizzard API rate limited (429). Retry-After: #{retry_after}s"
        end

        raise Error,
              "Blizzard API error: HTTP #{response.status}, body=#{response.body}"
      rescue Oj::ParseError, JSON::ParserError => e
        raise Error,
              "Blizzard API error: invalid JSON: #{e.message}\n#{response.body}"
      end
    # rubocop:enable Metrics/AbcSize
  end
end
