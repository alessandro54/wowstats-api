module Pvp
  module BracketConfig
    # top_n is the sole limiter — no rating_min. This naturally adapts to season
    # maturity: early season syncs fewer players (all available top), late season
    # caps at the configured maximum. See discovery/pvp/all-brackets.ipynb.
    FAMILY_DEFAULTS = {
      two_v_two:     { top_n: 2500, job_queue: :pvp_sync_2v2 },
      three_v_three: { top_n: 2500, job_queue: :pvp_sync_3v3 },
      shuffle_like:  { top_n: 500,  job_queue: :pvp_sync_shuffle },
      blitz_like:    { top_n: 500,  job_queue: :pvp_sync_blitz },
      default:       { top_n: 500,  job_queue: :default }
    }.freeze

    # Brackets to skip entirely during discovery — redundant or dead.
    # Classic RBG is dead (<5k entries, noisy data). Overalls are redundant
    # because their characters are fully covered by the per-spec brackets.
    # See discovery/pvp/rbg-brackets.ipynb.
    # Blizzard exposes "shuffle-overall" and "blitz-overall" bracket buckets
    # but they're redundant — every character also appears in the per-spec
    # brackets (shuffle-{class}-{spec}, blitz-{class}-{spec}) that already
    # cover the full ladder. Skip them at sync time so we don't pull data
    # we'll never read. Classic RBG is dead (<5k entries, noisy data).
    # See discovery/pvp/rbg-brackets.ipynb.
    SKIP_BRACKETS = %w[shuffle-overall blitz-overall rbg].freeze

    EXPLICIT = {}.freeze

    module_function

    def for(bracket)
      return EXPLICIT[bracket] if EXPLICIT.key?(bracket)

      family_key =
        case bracket
        when "2v2"
          :two_v_two
        when "3v3"
          :three_v_three
        when /\Ashuffle-/
          :shuffle_like
        when /\Ablitz-/
          :blitz_like
        else
          :default
        end

      FAMILY_DEFAULTS[family_key]
    end
  end
end
