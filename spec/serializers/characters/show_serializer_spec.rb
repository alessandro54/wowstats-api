require "rails_helper"

RSpec.describe Characters::ShowSerializer do
  let(:character) do
    instance_double("Character",
      id: 1, name: "Arthas", realm: "ragnaros", region: "eu",
      class_slug: "death-knight", race: "human", faction: "alliance",
      avatar_url: "https://cdn.example.com/avatar.jpg",
      inset_url: "https://cdn.example.com/inset.jpg",
      stat_pcts: { "HASTE_RATING" => 18 },
      spec_talent_loadout_codes: { "250" => "C0BAAA..." }
    ).tap do |c|
      allow(c).to receive(:character_items).and_return(
        instance_double("ActiveRecord::Relation", where: double(includes: []))
      )
    end
  end

  let(:pvp_entry) do
    double("PvpLeaderboardEntry",
      bracket: "2v2", region: "eu", rating: 2400,
      wins: 100, losses: 50, rank: 5, spec_id: 250
    )
  end

  subject(:result) do
    described_class.new(character, pvp_entries: [ pvp_entry ], primary_spec_id: 250).call
  end

  it "serializes character base fields" do
    expect(result[:name]).to eq("Arthas")
    expect(result[:realm]).to eq("ragnaros")
    expect(result[:region]).to eq("EU")
    expect(result[:class_slug]).to eq("death-knight")
    expect(result[:primary_spec_id]).to eq(250)
  end

  it "serializes pvp_entries" do
    entry = result[:pvp_entries].first
    expect(entry[:bracket]).to eq("2v2")
    expect(entry[:region]).to eq("EU")
    expect(entry[:rating]).to eq(2400)
  end

  it "returns empty equipment when no items" do
    expect(result[:equipment]).to eq([])
  end

  it "returns empty talents when primary_spec_id given but no assignments" do
    allow(TalentSpecAssignment).to receive(:where).and_return(double(pluck: []))
    expect(result[:talents]).to eq([])
  end

  context "when primary_spec_id is nil" do
    subject(:result) do
      described_class.new(character, pvp_entries: [], primary_spec_id: nil).call
    end

    it "returns empty equipment and talents" do
      expect(result[:equipment]).to eq([])
      expect(result[:talents]).to eq([])
    end
  end
end
