# app/services/base_service.rb
class BaseService
  def self.call(*args, **kwargs, &block)
    new(*args, **kwargs).call(&block)
  end

  private

    def log_info(msg)  = Rails.logger.info("[#{self.class.name}] #{msg}")
    def log_warn(msg)  = Rails.logger.warn("[#{self.class.name}] #{msg}")
    def log_error(msg) = Rails.logger.error("[#{self.class.name}] #{msg}")

    def success(payload = nil, message: nil, context: {})
      ServiceResult.success(payload, message: message, context: context)
    end

    def failure(error, message: nil, payload: nil, context: {}, captured: false)
      if error.is_a?(Exception) && !captured
        Sentry.capture_exception(error, extra: { service: self.class.name }.merge(context))
      end
      ServiceResult.failure(error, message: message, payload: payload, context: context)
    end

    def with_deadlock_retry(max_retries: 5)
      retries = 0
      begin
        yield
      rescue ActiveRecord::Deadlocked
        retries += 1
        raise if retries > max_retries

        sleep(rand * 0.1 * (2**retries))
        retry
      end
    end
end
