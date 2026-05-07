require "rails_helper"

RSpec.describe Pvp::BuildAggregationsService, type: :service do
  let(:season) { create(:pvp_season) }
  let(:cycle)  { create(:pvp_sync_cycle, pvp_season: season, status: "syncing_characters") }

  let(:success_result) { ServiceResult.success(10, context: { count: 10 }) }
  let(:failure_result) { ServiceResult.failure(StandardError.new("boom")) }

  before do
    allow(Pvp::Meta::ItemAggregationService).to    receive(:call).and_return(success_result)
    allow(Pvp::Meta::EnchantAggregationService).to receive(:call).and_return(success_result)
    allow(Pvp::Meta::GemAggregationService).to     receive(:call).and_return(success_result)
    allow(Pvp::Meta::TalentAggregationService).to  receive(:call).and_return(success_result)
    allow(Pvp::WarmMetaCacheJob).to            receive(:perform_later)
    allow(Pvp::PurgeStaleCharacterDataJob).to  receive(:perform_later)
    allow(Pvp::NotifyFailedCharactersJob).to        receive(:perform_later)
    allow(Pvp::SyncLogger).to                       receive(:cycle_complete)
    allow(Rails.cache).to                           receive(:increment)
    season.update!(live_pvp_sync_cycle_id: nil)
  end

  subject(:result) do
    described_class.call(
      pvp_season_id:    season.id,
      sync_cycle_id:    cycle.id,
      cycle_started_at: 1.minute.ago.to_s
    )
  end

  include_examples "service result interface"

  context "when season does not exist" do
    subject(:result) { described_class.call(pvp_season_id: 0) }

    it "returns success without running aggregations" do
      expect(Pvp::Meta::ItemAggregationService).not_to receive(:call)
      expect(result).to be_success
    end
  end

  context "when cycle is aborted" do
    before { cycle.update!(status: :aborted) }

    it "returns success without running aggregations" do
      expect(Pvp::Meta::ItemAggregationService).not_to receive(:call)
      expect(result).to be_success
    end
  end

  context "when all aggregations succeed" do
    it "returns success" do
      expect(result).to be_success
    end

    it "marks cycle as completed" do
      result
      expect(cycle.reload.status).to eq("completed")
    end

    it "sets season live_pvp_sync_cycle_id" do
      result
      expect(season.reload.live_pvp_sync_cycle_id).to eq(cycle.id)
    end

    it "bumps meta cache" do
      expect(Rails.cache).to receive(:increment)
      result
    end

    it "enqueues cache warm job (which notifies frontend when done)" do
      expect(Pvp::WarmMetaCacheJob).to receive(:perform_later)
      result
    end
  end

  context "when an aggregation fails" do
    before do
      allow(Pvp::Meta::ItemAggregationService).to receive(:call).and_return(failure_result)
      allow(Sentry).to receive(:capture_message)
      allow(TelegramNotifier).to receive(:send)
    end

    it "rolls back cycle to failed" do
      result
      expect(cycle.reload.status).to eq("failed")
    end

    it "does not promote cycle" do
      result
      expect(season.reload.live_pvp_sync_cycle_id).to be_nil
    end

    it "does not enqueue cache warm job" do
      expect(Pvp::WarmMetaCacheJob).not_to receive(:perform_later)
      result
    end

    it "captures a Sentry message" do
      expect(Sentry).to receive(:capture_message).with(
        "Aggregation cycle failed — live data preserved",
        hash_including(extra: hash_including(cycle_id: cycle.id))
      )
      result
    end
  end
end
