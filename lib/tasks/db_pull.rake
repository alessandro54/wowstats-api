namespace :db do
  # Pull the production primary database from Dokku via `postgres:export`
  # and restore locally using pg_restore. Connects as dokku@ using the
  # passwordless deploy key at ~/.ssh/dokku_deploy.
  #
  # Required env vars (add to .env):
  #   DOKKU_SSH_HOST — server IP or hostname, e.g. "178.156.204.200"
  #   DOKKU_DB       — Dokku postgres service name, e.g. "wow_meta_production"
  #
  # Usage:
  #   bundle exec rails db:pull
  #
  # Cached dump lives at tmp/wow_bis_prod.dump and is reused if <3h old.
  # Pass FORCE=1 to skip the cache and always pull fresh.
  #
  desc "Pull full production DB from Dokku and restore locally"
  task :pull, [:force] => :environment do |_t, args|
    return if Rails.env.production?

    db_name  = ENV.fetch("DOKKU_DB") { abort "Set DOKKU_DB in .env" }
    ssh_host = ENV.fetch("DOKKU_SSH_HOST") { abort "Set DOKKU_SSH_HOST in .env" }
    ssh_key  = File.expand_path("~/.ssh/dokku_deploy")
    local    = ActiveRecord::Base.configurations.find_db_config("development").database
    dump     = Rails.root.join("tmp/wow_bis_prod.dump").to_s
    max_age  = 3 * 60 * 60 # 3 hours in seconds

    # Fail fast if local Postgres is not reachable
    begin
      ActiveRecord::Base.connection.execute("SELECT 1")
    rescue => e
      abort "Local Postgres not reachable — is it running? (#{e.message})"
    end

    fresh = File.exist?(dump) && (Time.now - File.mtime(dump)) < max_age
    forced = ENV["FORCE"] == "1" || args[:force] == "force"

    if fresh && !forced
      age_min = ((Time.now - File.mtime(dump)) / 60).round
      puts "→ Reusing cached dump (#{age_min}m old, #{(File.size(dump) / 1024.0 / 1024.0).round(1)} MB) — pass FORCE=1 to refresh"
    else
      puts "→ Exporting #{db_name} from #{ssh_host}..."
      system("ssh -i #{ssh_key} dokku@#{ssh_host} postgres:export #{db_name} > #{dump}") || abort("Export failed")
      puts "  Dump saved (#{(File.size(dump) / 1024.0 / 1024.0).round(1)} MB)"
    end

    queue_db = ActiveRecord::Base.configurations.configs_for(env_name: "development", name: "queue")&.database ||
               "#{local}_queue"

    puts "→ Dropping and recreating '#{local}'..."
    ActiveRecord::Base.connection.execute(<<~SQL)
      SELECT pg_terminate_backend(pid)
      FROM pg_stat_activity
      WHERE datname = '#{local}' AND pid <> pg_backend_pid()
    SQL
    ActiveRecord::Base.connection_handler.clear_all_connections!
    system("dropdb --if-exists #{local}") || abort("dropdb failed")
    system("createdb #{local}") || abort("createdb failed")

    system("createdb #{queue_db} 2>/dev/null")

    puts "→ Restoring into '#{local}'..."
    system("pg_restore --no-acl --no-owner -d #{local} #{dump}")
    count = ActiveRecord::Base.connection.execute("SELECT COUNT(*) FROM pvp_seasons").first["count"]
    abort("Restore failed — no data found") if count.to_i.zero?

    ActiveRecord::Base.connection.execute(
      "UPDATE ar_internal_metadata SET value = '#{Rails.env}' WHERE key = 'environment'"
    )

    puts "→ Ensuring queue database schema..."
    system("bundle exec rails db:schema:load:queue")

    puts "✓ Done. Local database '#{local}' now mirrors production."
  end
end
