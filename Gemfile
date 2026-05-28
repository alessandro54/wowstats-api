source "https://rubygems.org"

gem "avo"

# Main Rails framework (API, ActiveRecord, ActionPack)
gem "rails", "~> 8.1.1"

# Boot-time caching for faster startup
gem "bootsnap", "~> 1.24", require: false

# Fiber-based cooperative concurrency (replaces thread pools)
gem "async", "~> 2.39"

# HTTP client
gem "httpx", "~> 1.7"

# Mission Control UI for jobs
gem "mission_control-jobs", "~> 1.1"

# Clean, single-line request logging
gem "lograge", "~> 0.14"

# Fast, optimized JSON parser/serializer
gem "oj", "~> 3.17"

# Explicit OpenSSL dependency (fix macOS SSL issues)
gem "openssl"

# PostgreSQL adapter for ActiveRecord
gem "pg", "~> 1.6"

# Production web server
gem "puma", "~> 8.0"
gem "thruster", require: false

# Rack-level request throttling and blocking
gem "rack-attack", "~> 6.7"

# Asset pipeline replacement for Rails 7+/8
gem "propshaft", "~> 1.3"

# PostgreSQL-backed ActionCable, Rails.cache, background jobs
gem "solid_cable"          # ActionCable over PostgreSQL
gem "solid_cache"          # Rails.cache backed by PostgreSQL
gem "solid_queue"          # Background jobs backed by PostgreSQL


# Timezone data for Windows/JRuby
gem "tzinfo-data", platforms: %i[windows jruby]

# Error tracking and performance monitoring
gem "sentry-rails"
gem "sentry-ruby"

group :development do
  # Auto-add schema annotations to models
  gem "annotaterb", "~> 4.20"

  # N+1 query detection
  gem "bullet"

  gem "rbs", require: false

  # Static type checking
  gem "steep", require: false

  # Git hooks manager
  gem "lefthook", require: false
end

group :development, :test do
  # Pretty-print Ruby objects
  gem "amazing_print", "~> 2.0", require: false

  # Security scanner for Rails apps
  gem "brakeman", require: false

  # Security audit of dependency tree
  gem "bundler-audit", require: false

  # Ruby debugger
  gem "debug",
      "~> 1.11",
      platforms: %i[mri windows],
      require:   "debug/prelude"

  gem "dotenv"

  # Factories for tests
  gem "factory_bot_rails", "~> 6.5"

  # RSpec testing framework for Railshttps://www.youtube.com/watch?v=KzI9mwk3pIQ
  gem "rspec-rails", "~> 8.0"

  # RuboCop integrations
  gem "rubocop-factory_bot", require: false
  gem "rubocop-rails-omakase", "~> 1.1", require: false
  gem "rubocop-rake", require: false
  gem "rubocop-rspec", require: false
end

group :test do
  gem "database_cleaner-active_record", "~> 2.2"
  gem "faker", "~> 3.8"
  gem "shoulda-matchers", "~> 7.0"
  gem "simplecov", "~> 0.22", require: false
end
