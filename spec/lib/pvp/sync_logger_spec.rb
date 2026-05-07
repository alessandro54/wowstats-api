require "rails_helper"

RSpec.describe Pvp::SyncLogger do
  describe ".snapshots_inserted" do
    let(:leaderboard) { create(:pvp_leaderboard) }

    it "logs the snapshot count and leaderboard label" do
      fake_logger = instance_double(Logger)
      allow(described_class).to receive(:logger).and_return(fake_logger)
      expect(fake_logger).to receive(:info).with(/snapshots inserted=42/i)
      described_class.snapshots_inserted(count: 42, leaderboard: leaderboard)
    end
  end
end
