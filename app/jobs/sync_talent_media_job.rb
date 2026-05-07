class SyncTalentMediaJob < ApplicationJob
  queue_as :default

  CONCURRENCY = ENV.fetch("TALENT_MEDIA_CONCURRENCY", 10).to_i

  retry_on Blizzard::Client::Error, wait: :polynomially_longer, attempts: 3

  def perform(region: "us", locale: "en_US")
    service = Blizzard::Data::Talents::SyncTalentMediaService.new(region: region, locale: locale)
    talents = service.incomplete_scope.to_a

    return if talents.empty?

    concurrency = safe_concurrency(CONCURRENCY, talents.size, threads: CONCURRENCY)
    run_with_threads(talents, concurrency: concurrency) do |talent|
      service.sync_one(talent)
    end

    Rails.logger.info("[SyncTalentMediaJob] Processed #{talents.size} talents")
  end
end
