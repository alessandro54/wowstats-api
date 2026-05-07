require "rails_helper"

RSpec.describe SyncTalentTreesJob, type: :job do
  let(:result) do
    instance_double(
      "ServiceResult",
      success?: true,
      context:  { talents: 0, edges: 0 }
    )
  end

  before do
    allow(Blizzard::Data::Talents::SyncTreeService).to receive(:call).and_return(result)
  end

  describe "#perform" do
    it "accepts no args (defaults)" do
      described_class.new.perform
      expect(Blizzard::Data::Talents::SyncTreeService)
        .to have_received(:call).with(region: "us", locale: "en_US", force: false)
    end

    it "accepts keyword args (Avo / perform_later style)" do
      described_class.new.perform(force: true)
      expect(Blizzard::Data::Talents::SyncTreeService)
        .to have_received(:call).with(region: "us", locale: "en_US", force: true)
    end

    it "accepts positional Hash arg" do
      described_class.new.perform({ force: true })
      expect(Blizzard::Data::Talents::SyncTreeService)
        .to have_received(:call).with(region: "us", locale: "en_US", force: true)
    end

    it "accepts Solid Queue recurring.yml format (array-of-pairs)" do
      # YAML hash `args: { force: true }` arrives serialized as `[[:force, true]]`.
      # ActiveJob calls perform(*[[:force, true]]) → perform([:force, true]).
      described_class.new.perform([ :force, true ])
      expect(Blizzard::Data::Talents::SyncTreeService)
        .to have_received(:call).with(region: "us", locale: "en_US", force: true)
    end

    it "accepts string keys from JSON-deserialized args" do
      described_class.new.perform({ "force" => true })
      expect(Blizzard::Data::Talents::SyncTreeService)
        .to have_received(:call).with(region: "us", locale: "en_US", force: true)
    end

    it "accepts multi-key array-of-pairs" do
      described_class.new.perform([ :region, "eu" ], [ :force, true ])
      expect(Blizzard::Data::Talents::SyncTreeService)
        .to have_received(:call).with(region: "eu", locale: "en_US", force: true)
    end
  end
end
