module Blizzard
  # Round-robin pool of Auth instances — one per registered Blizzard OAuth app.
  # Each credential gets a separate rate-limit bucket per region (keyed by
  # "client_id:region" in RateLimiter), so N credentials × 2 regions give
  # N × 2 × 36,000 req/hr total sustained throughput.
  #
  # Configure via Rails credentials or ENV:
  #   Primary:   blizzard.client_id / blizzard.client_secret
  #              (or BLIZZARD_CLIENT_ID / BLIZZARD_CLIENT_SECRET)
  #   Secondary: blizzard.client_id_2 / blizzard.client_secret_2
  #              (or BLIZZARD_CLIENT_ID_2 / BLIZZARD_CLIENT_SECRET_2)
  #
  # If only one credential is configured, AuthPool behaves identically to
  # creating a single Auth instance — no behavioral change.
  class AuthPool
    @pool          = nil
    @counter       = 0
    @pool_mutex    = Mutex.new
    @counter_mutex = Mutex.new

    def self.next_auth
      pool = instance
      return pool.first if pool.size == 1

      idx = @counter_mutex.synchronize do
        current  = @counter
        @counter = (@counter + 1) % pool.size
        current
      end

      pool[idx]
    end

    # For tests: rebuild the pool on next access.
    def self.reset!
      @pool_mutex.synchronize do
        @pool    = nil
        @counter = 0
      end
    end

    def self.instance
      @pool_mutex.synchronize { @pool ||= build_pool }
    end
    private_class_method :instance

    # rubocop:disable Metrics/AbcSize
    def self.build_pool
      pairs = [
        {
          id:     Rails.application.credentials.dig(:blizzard, :client_id)     || ENV["BLIZZARD_CLIENT_ID"],
          secret: Rails.application.credentials.dig(:blizzard, :client_secret) || ENV["BLIZZARD_CLIENT_SECRET"]
        },
        {
          id:     Rails.application.credentials.dig(:blizzard, :client_id_2)     || ENV["BLIZZARD_CLIENT_ID_2"],
          secret: Rails.application.credentials.dig(:blizzard, :client_secret_2) || ENV["BLIZZARD_CLIENT_SECRET_2"]
        }
      ].select { |p| p[:id].present? && p[:secret].present? }

      pairs.map { |p| Auth.new(client_id: p[:id], client_secret: p[:secret]) }
    end
    # rubocop:enable Metrics/AbcSize
    private_class_method :build_pool
  end
end
