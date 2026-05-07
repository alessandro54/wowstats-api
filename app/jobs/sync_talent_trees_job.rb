class SyncTalentTreesJob < ApplicationJob
  queue_as :default

  retry_on Blizzard::Client::Error, wait: :polynomially_longer, attempts: 3

  def perform(*args, **kwargs)
    opts = normalize_opts(args, kwargs)
    region = opts.fetch(:region, "us")
    locale = opts.fetch(:locale, "en_US")
    force  = opts.fetch(:force, false)

    result = Blizzard::Data::Talents::SyncTreeService.call(region:, locale:, force:)

    if result.success?
      ctx = result.context
      Rails.logger.info(
        "[SyncTalentTreesJob] Done — talents: #{ctx[:talents]}, edges: #{ctx[:edges]}"
      )
    else
      Rails.logger.error("[SyncTalentTreesJob] Failed: #{result.error}")
    end
  end

  private

    # Solid Queue's recurring.yml serializes hash args as array-of-pairs:
    # `args: { force: true }` arrives as `[[:force, true]]`. ActiveJob kwargs
    # arrive normally. Accept both.
    def normalize_opts(args, kwargs)
      return kwargs if kwargs.any?
      return args.first.transform_keys(&:to_sym) if args.first.is_a?(Hash)
      return Hash[*args.flatten].transform_keys(&:to_sym) if args.first.is_a?(Array)

      {}
    end
end
