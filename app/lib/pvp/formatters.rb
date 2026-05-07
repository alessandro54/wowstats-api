module Pvp
  module Formatters
    module_function

    # Full elapsed: seconds → "12s" / "5m 12s" / "2h 15m".
    # Used in user-facing Telegram messages.
    def elapsed(seconds)
      seconds = seconds.abs
      return "#{seconds.round(0)}s"                                   if seconds < 60
      return "#{(seconds / 60).floor}m #{(seconds % 60).round}s"      if seconds < 3600

      h = (seconds / 3600).floor
      m = ((seconds % 3600) / 60).round
      "#{h}h #{m}m"
    end

    # Short elapsed: seconds → "12.3s" / "5m 12s" (caps at minutes).
    # Used in log lines where hour-scale values are rare.
    def elapsed_short(seconds)
      seconds = seconds.abs
      return "#{seconds.round(1)}s" if seconds < 60

      m = (seconds / 60).floor
      s = (seconds % 60).round
      "#{m}m #{s}s"
    end
  end
end
