# == Schema Information
#
# Table name: talent_sync_runs
# Database name: primary
#
#  id            :bigint           not null, primary key
#  completed_at  :datetime
#  counts        :jsonb            not null
#  error_message :text
#  failed_specs  :jsonb            not null
#  force         :boolean          default(FALSE), not null
#  locale        :string           not null
#  region        :string           not null
#  regression    :jsonb            not null
#  started_at    :datetime         not null
#  status        :string           default("running"), not null
#  tsa_counts    :jsonb            not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#
# Indexes
#
#  index_talent_sync_runs_on_started_at             (started_at)
#  index_talent_sync_runs_on_status_and_started_at  (status,started_at)
#
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
