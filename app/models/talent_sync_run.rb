class TalentSyncRun < ApplicationRecord
  STATUSES = %w[running success failure aborted_regression].freeze

  validates :status, inclusion: { in: STATUSES }
  validates :region, :locale, :started_at, presence: true

  scope :recent,  -> { order(started_at: :desc) }
  scope :success, -> { where(status: "success") }

  # Last successful run for this region. Used as the baseline for
  # regression checks ("did counts collapse vs prior good sync?").
  def self.last_success_for(region)
    success.where(region: region).order(started_at: :desc).first
  end

  def aborted_regression? = status == "aborted_regression"
end
