require "net/http"
require "uri"

# Sends fire-and-forget Telegram messages via Bot API.
# No-ops silently when TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID are unset.
module TelegramNotifier
  API_URL = "https://api.telegram.org"

  def self.allowed_chat_ids
    raw = ENV["TELEGRAM_ALLOWED_CHAT_IDS"].to_s
    raw.split(",").map(&:strip).reject(&:empty?)
  end

  def self.allowed?(chat_id)
    allowed_chat_ids.include?(chat_id.to_s)
  end

  # Broadcast to the default TELEGRAM_CHAT_ID (job notifications).
  # Returns the new message's Telegram message_id (Integer) on success, else nil.
  # rubocop:disable Metrics/AbcSize
  def self.send(text)
    token = ENV["TELEGRAM_BOT_TOKEN"]
    chat  = ENV["TELEGRAM_CHAT_ID"]
    return unless token.present? && chat.present?

    post_message(token, chat, text)
  end

  # Edit an existing broadcast message in place (one self-updating message
  # instead of a new one per update). No-ops if message_id is blank.
  def self.edit(message_id, text)
    token = ENV["TELEGRAM_BOT_TOKEN"]
    chat  = ENV["TELEGRAM_CHAT_ID"]
    return unless token.present? && chat.present? && message_id.present?

    data = { chat_id: chat, message_id: message_id, text: text, parse_mode: "HTML" }
    post_form("bot#{token}/editMessageText", data)
  rescue StandardError => e
    Rails.logger.error("[TelegramNotifier] edit: #{e.message}")
  end

  # Reply to a specific chat_id (bot commands).
  def self.reply(chat_id, text)
    token = ENV["TELEGRAM_BOT_TOKEN"]
    return unless token.present?

    post_message(token, chat_id, text)
  end

  # Reply with Telegram inline keyboard buttons.
  # buttons: [[{text: "Label", callback_data: "action:id"}]]
  def self.reply_with_buttons(chat_id, text, buttons)
    token = ENV["TELEGRAM_BOT_TOKEN"]
    return unless token.present?

    post_message(token, chat_id, text, reply_markup: { inline_keyboard: buttons })
  end

  # Acknowledge a callback_query to dismiss the loading spinner.
  def self.answer_callback_query(callback_query_id, text: nil)
    token = ENV["TELEGRAM_BOT_TOKEN"]
    return unless token.present?

    post_answer_callback(token, callback_query_id, text)
  end
  # rubocop:enable Metrics/AbcSize

  # Send a plain-text file as a Telegram document.
  def self.send_document(filename:, content:, caption: nil)
    token = ENV["TELEGRAM_BOT_TOKEN"]
    chat  = ENV["TELEGRAM_CHAT_ID"]
    return unless token.present? && chat.present?

    post_document(token, chat, filename: filename, content: content, caption: caption)
  rescue StandardError => e
    Rails.logger.error("[TelegramNotifier] send_document: #{e.message}")
  end

  def self.post_message(token, chat_id, text, reply_markup: nil)
    data = { chat_id: chat_id, text: text, parse_mode: "HTML" }
    data[:reply_markup] = reply_markup.to_json if reply_markup
    response = post_form("bot#{token}/sendMessage", data)
    extract_message_id(response)
  rescue StandardError => e
    Rails.logger.error("[TelegramNotifier] #{e.message}")
    nil
  end

  def self.extract_message_id(response)
    return nil unless response.is_a?(Net::HTTPResponse)

    JSON.parse(response.body).dig("result", "message_id")
  rescue StandardError
    nil
  end

  def self.post_document(token, chat_id, filename:, content:, caption:)
    uri      = URI("#{API_URL}/bot#{token}/sendDocument")
    boundary = "----TelegramBoundary#{SecureRandom.hex(8)}"
    http     = build_http(uri, open_timeout: 5, read_timeout: 10)
    request  = Net::HTTP::Post.new(uri.request_uri)
    request["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
    request.body = build_multipart(boundary, chat_id: chat_id, filename: filename, content: content, caption: caption)
    http.request(request)
  end

  def self.post_answer_callback(token, callback_query_id, text)
    data = { callback_query_id: callback_query_id }
    data[:text] = text if text.present?
    post_form("bot#{token}/answerCallbackQuery", data)
  rescue StandardError => e
    Rails.logger.error("[TelegramNotifier] answer_callback: #{e.message}")
  end

  def self.post_form(path, data)
    uri     = URI("#{API_URL}/#{path}")
    http    = build_http(uri)
    request = Net::HTTP::Post.new(uri.request_uri)
    request["Content-Type"] = "application/x-www-form-urlencoded"
    request.body = URI.encode_www_form(data)
    http.request(request)
  end

  def self.build_http(uri, open_timeout: 3, read_timeout: 5)
    http              = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl      = true
    http.open_timeout = open_timeout
    http.read_timeout = read_timeout
    http
  end

  def self.build_multipart(boundary, chat_id:, filename:, content:, caption:)
    parts = []
    parts << "--#{boundary}\r\nContent-Disposition: form-data; name=\"chat_id\"\r\n\r\n#{chat_id}"
    if caption.present?
      parts << "--#{boundary}\r\nContent-Disposition: form-data; name=\"caption\"\r\n\r\n#{caption}"
    end
    parts << "--#{boundary}\r\nContent-Disposition: form-data; name=\"document\"; " \
             "filename=\"#{filename}\"\r\nContent-Type: text/plain\r\n\r\n#{content}"
    parts.join("\r\n") + "\r\n--#{boundary}--"
  end

  private_class_method :post_message, :extract_message_id, :post_document, :post_answer_callback,
                       :post_form, :build_http, :build_multipart
end
