# == Schema Information
#
# Table name: pvp_leaderboards
# Database name: primary
#
#  id             :bigint           not null, primary key
#  bracket        :string
#  last_synced_at :datetime
#  region         :string
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  pvp_season_id  :bigint           not null
#
# Indexes
#
#  idx_leaderboards_season_bracket_region   (pvp_season_id,bracket,region) UNIQUE
#  index_pvp_leaderboards_on_pvp_season_id  (pvp_season_id)
#
# Foreign Keys
#
#  fk_rails_...  (pvp_season_id => pvp_seasons.id)
#
class PvpLeaderboard < ApplicationRecord
  belongs_to :pvp_season

  has_many :entries, class_name: "PvpLeaderboardEntry", dependent: :destroy

  OVERALL_BRACKETS = Pvp::BracketResolver::AGGREGATES

  scope :for_bracket, ->(bracket) { Pvp::BracketResolver.scope(self, bracket) }

  def get_top_n(n, spec_id: nil)
    scope = entries
    scope = scope.where(spec_id: spec_id) if spec_id.present?
    scope.order(rank: :asc).limit(n)
  end
end
