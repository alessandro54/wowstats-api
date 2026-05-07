require "rails_helper"

RSpec.describe SyncTalentMediaJob, type: :job do
  let(:service_double) { instance_double(Blizzard::Data::Talents::SyncTalentMediaService) }
  let(:talent_1) { build_stubbed(:talent) }
  let(:talent_2) { build_stubbed(:talent) }

  before do
    allow(Blizzard::Data::Talents::SyncTalentMediaService).to receive(:new).and_return(service_double)
    allow(service_double).to receive(:incomplete_scope).and_return([ talent_1, talent_2 ])
    allow(service_double).to receive(:sync_one)
  end

  it "calls sync_one for each incomplete talent" do
    expect(service_double).to receive(:sync_one).with(talent_1)
    expect(service_double).to receive(:sync_one).with(talent_2)

    described_class.perform_now
  end

  it "does nothing when no talents are incomplete" do
    allow(service_double).to receive(:incomplete_scope).and_return([])
    expect(service_double).not_to receive(:sync_one)

    described_class.perform_now
  end

  it "passes region and locale to the service" do
    expect(Blizzard::Data::Talents::SyncTalentMediaService).to receive(:new)
      .with(region: "eu", locale: "fr_FR")
      .and_return(service_double)

    described_class.perform_now(region: "eu", locale: "fr_FR")
  end
end
