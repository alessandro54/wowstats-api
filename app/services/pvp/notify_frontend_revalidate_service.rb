module Pvp
  class NotifyFrontendRevalidateService < BaseService
    MAX_RETRIES = 3

    def call
      url    = ENV["FRONTEND_URL"]
      secret = ENV["REVALIDATE_SECRET"]

      unless url.present? && secret.present?
        log_warn("Skipped — FRONTEND_URL or REVALIDATE_SECRET not set")
        return success(nil)
      end

      post_with_retries(url, secret)
      success(nil)
    end

    private

      def post_with_retries(url, secret)
        attempt = 0
        begin
          attempt += 1
          response = HTTPX.post("#{url}/api/revalidate", headers: { "x-revalidate-secret" => secret })
          raise "unexpected status #{response.status}: #{response.body}" unless response.status == 200

          log_info("Revalidated (attempt #{attempt})")
        rescue => e
          log_warn("Attempt #{attempt} failed: #{e.message}")
          retry if attempt < MAX_RETRIES
          log_error("All #{MAX_RETRIES} attempts failed")
        end
      end
  end
end
