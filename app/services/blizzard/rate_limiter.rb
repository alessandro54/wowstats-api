module Blizzard
  # Thread-safe dual token bucket rate limiter, one instance per credential+region pair.
  # Enforces both Blizzard API limits simultaneously:
  #   - Per-second:  100 req/s hard limit  → 429 if exceeded
  #   - Per-hour:  36,000 req/hr soft limit → degraded service if exceeded
  #
  # Blizzard enforces limits per-credential per-region (us/eu have independent quotas).
  # Keying by "client_id:region" gives each region its own bucket, so N credentials
  # give N × 2 × 36,000 req/hr total across both regions.
  #
  # Usage (automatic via Client#get — no manual calls needed):
  #   RateLimiter.for_credential(auth.client_id).acquire
  #
  # Tune via env vars:
  #   PVP_BLIZZARD_RPS          — per-second cap (default 95)
  #   PVP_BLIZZARD_HOURLY_QUOTA — hourly cap (default 36_000)
  class RateLimiter
    DEFAULT_RPS          = ENV.fetch("PVP_BLIZZARD_RPS", 95).to_f
    DEFAULT_HOURLY_QUOTA = ENV.fetch("PVP_BLIZZARD_HOURLY_QUOTA", 36_000).to_f

    # One limiter per credential (client_id), created on first use.
    @limiters = {}
    @mutex    = Mutex.new

    def self.for_credential(client_id)
      @mutex.synchronize { @limiters[client_id] ||= new }
    end

    # For tests: drop all cached limiters.
    def self.reset!
      @mutex.synchronize { @limiters = {} }
    end

    def initialize(rps: DEFAULT_RPS, hourly_quota: DEFAULT_HOURLY_QUOTA)
      @rps          = rps.to_f
      @hourly_quota = hourly_quota.to_f
      @hourly_rps   = @hourly_quota / 3600.0 # 10.0 tokens/s at default quota

      # Start both buckets full so the first burst isn't throttled.
      @tokens        = @rps
      @hourly_tokens = @hourly_quota
      @last_refill   = clock
      @mutex         = Mutex.new
    end

    # Block until a token is available in BOTH buckets, then consume one from each.
    # Sleeps outside the mutex so other threads can refill concurrently.
    # Jitter (+0–25%) staggers wakeups and prevents the thundering herd.
    def acquire
      loop do
        wait = nil

        @mutex.synchronize do
          refill

          if @tokens >= 1.0 && @hourly_tokens >= 1.0
            @tokens        -= 1.0
            @hourly_tokens -= 1.0
            return
          end

          # Sleep until whichever bucket is the bottleneck refills enough.
          per_second_wait = @tokens        < 1.0 ? (1.0 - @tokens)        / @rps        : 0.0
          hourly_wait     = @hourly_tokens < 1.0 ? (1.0 - @hourly_tokens) / @hourly_rps : 0.0
          wait = [ per_second_wait, hourly_wait ].max
        end

        sleep(wait * (1.0 + rand * 0.25))
      end
    end

    # Called when a real 429 slips through. Drains both buckets below zero so
    # every thread backs off for drain_seconds — prevents cascading 429s.
    def penalize!(drain_seconds: 2.0)
      @mutex.synchronize do
        @tokens        = [ -drain_seconds * @rps,        @tokens        ].min
        @hourly_tokens = [ -drain_seconds * @hourly_rps, @hourly_tokens ].min
        @last_refill   = clock
      end
    end

    private

      def refill
        now     = clock
        elapsed = now - @last_refill

        @tokens        = [ @tokens        + elapsed * @rps,        @rps          ].min
        @hourly_tokens = [ @hourly_tokens + elapsed * @hourly_rps, @hourly_quota ].min

        @last_refill = now
      end

      # Monotonic clock avoids drift during system clock adjustments.
      def clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
  end
end
