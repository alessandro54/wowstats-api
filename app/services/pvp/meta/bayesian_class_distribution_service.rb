# frozen_string_literal: true

module Pvp
  module Meta
    # Bayesian hierarchical model for class/spec distribution rankings.
    #
    # Rating:   Normal-Normal conjugate model with empirical Bayes hyperparameters.
    # Win rate: Beta-Binomial conjugate model with method-of-moments priors.
    #
    # All hyperparameters (mu0, sigma2, tau2, alpha0, beta0) are estimated from
    # the data each call — no hand-tuned constants. Shrinkage is mathematically
    # optimal (James-Stein) and adapts to season maturity automatically.
    #
    # See discovery/pvp/meta-scoring-study.ipynb for derivation and validation.
    class BayesianClassDistributionService < BaseService
      MIN_PLAYERS = 3

      # Role-dependent scoring weights: [rating, winrate, presence]
      # Presence (log-transformed) is the most reliable signal on shared ladders (arena).
      # Winrate is least reliable — MMR forces everyone toward 50% over time.
      # Healer: presence is heavily indicative of actual power (bottleneck effect).
      #
      # Shuffle/Blitz have per-spec ladders so presence is meaningless (~equal for all).
      # Use performance-only weights for those brackets.
      ARENA_WEIGHTS = {
        dps:    { rating: 0.40, winrate: 0.15, presence: 0.45 },
        healer: { rating: 0.25, winrate: 0.15, presence: 0.60 },
        tank:   { rating: 0.25, winrate: 0.15, presence: 0.60 }
      }.freeze

      SOLO_WEIGHTS = {
        dps:    { rating: 0.65, winrate: 0.35, presence: 0.0 },
        healer: { rating: 0.55, winrate: 0.45, presence: 0.0 },
        tank:   { rating: 0.55, winrate: 0.45, presence: 0.0 }
      }.freeze

      DEFAULT_WEIGHTS = ARENA_WEIGHTS[:dps].freeze

      SOLO_BRACKETS = %w[shuffle blitz].freeze

      def initialize(season:, bracket:, region:, role: nil)
        @season  = season
        @bracket = bracket
        @region  = region
        @role    = role&.to_sym
      end

      def call
        entries = load_entries
        return [] if entries.empty?

        spec_groups = group_by_spec(entries)
        return [] if spec_groups.empty?

        hyperparams = estimate_hyperparams(spec_groups, entries)
        rows = spec_groups.filter_map { |group| build_row(group, hyperparams) }
        return [] if rows.empty?

        score_and_rank(rows)
      end

      private

        attr_reader :season, :bracket, :region, :role

        SpecGroup = Struct.new(
          :spec_id, :class_slug, :spec_slug, :role,
          :n, :total_in_bracket,
          :mean_rating, :var_rating,
          :total_wins, :total_losses, :total_games,
          keyword_init: true
        )

        Hyperparams = Struct.new(:mu0, :sigma2, :tau2, :alpha0, :beta0, keyword_init: true)

        def load_entries
          scope = PvpLeaderboardEntry
            .joins(:pvp_leaderboard)
            .merge(PvpLeaderboard.where(pvp_season_id: season.id).for_bracket(bracket))
            .where.not(spec_id: nil, rating: nil)

          scope = scope.where(pvp_leaderboards: { region: region }) if region
          scope.pluck(:spec_id, :rating, :wins, :losses)
        end

        # rubocop:disable Metrics/MethodLength, Metrics/AbcSize, Metrics/BlockLength
        def group_by_spec(entries)
          # Group all entries by spec_id
          by_spec = entries.group_by(&:first)

          by_spec.filter_map do |spec_id, spec_entries|
            spec_data = ::Wow::Catalog::SPECS[::Wow::Catalog.normalize_spec_id(spec_id)]
            next unless spec_data

            spec_role = spec_data[:role]
            next if role && spec_role != role

            # Sort by rating desc, take top 50% to measure ceiling
            # without low-skill drag from popular specs
            sorted = spec_entries.sort_by { |e| -e[1] }
            total_in_bracket = sorted.size
            sample_n = [ 1, (total_in_bracket / 2.0).ceil ].max
            top = sorted.first(sample_n)

            next if top.size < MIN_PLAYERS

            ratings = top.map { |e| e[1].to_f }
            wins    = top.sum { |e| e[2].to_i }
            losses  = top.sum { |e| e[3].to_i }

            mean_r = ratings.sum / ratings.size
            var_r  = if ratings.size > 1
              ratings.sum { |r| (r - mean_r)**2 } / (ratings.size - 1)
            else
              0.0
            end

            SpecGroup.new(
              spec_id:          ::Wow::Catalog.normalize_spec_id(spec_id),
              class_slug:       spec_data[:class_slug],
              spec_slug:        spec_data[:spec_slug],
              role:             spec_role,
              n:                top.size,
              total_in_bracket: total_in_bracket,
              mean_rating:      mean_r,
              var_rating:       var_r,
              total_wins:       wins,
              total_losses:     losses,
              total_games:      wins + losses
            )
          end
        end
        # rubocop:enable Metrics/MethodLength, Metrics/AbcSize, Metrics/BlockLength

        # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
        def estimate_hyperparams(spec_groups, _entries)
          # mu0: grand mean of spec means
          means = spec_groups.map(&:mean_rating)
          mu0 = means.sum / means.size

          # sigma2: pooled within-spec variance
          vars = spec_groups.select { |g| g.var_rating.positive? }.map(&:var_rating)
          sigma2 = vars.any? ? vars.sum / vars.size : mean_variance(means)

          # tau2: between-spec variance (method of moments)
          var_of_means = mean_variance(means)
          mean_sampling_var = spec_groups.sum { |g| sigma2 / g.n } / spec_groups.size
          tau2 = [ 0.0, var_of_means - mean_sampling_var ].max
          tau2 = sigma2 / 10.0 if tau2.zero?

          # Beta prior for win rate (method of moments)
          winrates = spec_groups.select { |g| g.total_games.positive? }.map { |g| g.total_wins.to_f / g.total_games }
          wr_mean = winrates.sum / winrates.size
          wr_var  = mean_variance(winrates)

          alpha0, beta0 = if wr_var.positive? && wr_var < wr_mean * (1 - wr_mean)
            common = wr_mean * (1 - wr_mean) / wr_var - 1
            [ wr_mean * common, (1 - wr_mean) * common ]
          else
            [ 50.0, 50.0 ]
          end

          Hyperparams.new(mu0: mu0, sigma2: sigma2, tau2: tau2, alpha0: alpha0, beta0: beta0)
        end
        # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

        # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
        def build_row(group, hp)
          # Rating posterior (Normal-Normal)
          b_k       = hp.tau2 / (hp.tau2 + hp.sigma2 / group.n)
          theta_hat = b_k * group.mean_rating + (1 - b_k) * hp.mu0
          v_k       = 1.0 / (group.n / hp.sigma2 + 1.0 / hp.tau2)

          rating_ci_low  = theta_hat - 1.645 * Math.sqrt(v_k)
          rating_ci_high = theta_hat + 1.645 * Math.sqrt(v_k)

          # Win rate posterior (Beta-Binomial)
          alpha_post = hp.alpha0 + group.total_wins
          beta_post  = hp.beta0 + group.total_losses
          wr_hat     = alpha_post / (alpha_post + beta_post)

          {
            class:            group.class_slug,
            spec:             group.spec_slug,
            spec_id:          group.spec_id,
            role:             group.role,
            count:            group.n,
            total_in_bracket: group.total_in_bracket,
            mean_rating:      group.mean_rating.round(1),
            theta_hat:        theta_hat.round(1),
            b_k:              b_k.round(4),
            rating_ci_low:    rating_ci_low.round(1),
            rating_ci_high:   rating_ci_high.round(1),
            raw_winrate:      group.total_games.positive? ? (group.total_wins.to_f / group.total_games).round(4) : 0.5,
            wr_hat:           wr_hat.round(4),
            total_games:      group.total_games,
            total_wins:       group.total_wins
          }
        end
        # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

        # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
        def score_and_rank(rows)
          r_min, r_max = rows.map { |r| r[:theta_hat] }.minmax
          w_min, w_max = rows.map { |r| r[:wr_hat] }.minmax

          # Log-transform presence: ln(1+n) expands low-end variance
          # (1% → 3% matters more than 10% → 12%)
          log_pres = rows.map { |r| Math.log(1 + r[:count]) }
          p_min, p_max = log_pres.minmax

          r_range = r_max - r_min
          w_range = w_max - w_min
          p_range = p_max - p_min

          rows.each_with_index do |row, i|
            norm_r = r_range.positive? ? (row[:theta_hat] - r_min) / r_range : 0.5
            norm_w = w_range.positive? ? (row[:wr_hat] - w_min) / w_range : 0.5
            norm_p = p_range.positive? ? (log_pres[i] - p_min) / p_range : 0.5

            # Hybrid scoring: B_k penalizes inferred performance metrics (rating,
            # winrate) which are subject to high variance at low sample sizes.
            # Presence is an observed fact — no confidence penalty needed.
            weight_table = SOLO_BRACKETS.include?(bracket) ? SOLO_WEIGHTS : ARENA_WEIGHTS
            weights = weight_table.fetch(row[:role], DEFAULT_WEIGHTS)
            performance = norm_r * weights[:rating] + norm_w * weights[:winrate]
            row[:score] = (performance * row[:b_k] + norm_p * weights[:presence]).round(4)
          end

          rows.sort_by { |r| -r[:score] }
        end
        # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

        def mean_variance(values)
          return 0.0 if values.size < 2

          mean = values.sum / values.size
          values.sum { |v| (v - mean)**2 } / (values.size - 1)
        end
    end
  end
end
