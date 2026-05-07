require "rails_helper"

RSpec.describe Pvp::Meta::ItemSerializer do
  let(:item) do
    instance_double("Item",
      id:          10,
      blizzard_id: 99_999,
      icon_url:    "https://cdn.example.com/icon.jpg",
      quality:     "EPIC"
    ).tap { |d| allow(d).to receive(:t).with("name", locale: "en_US").and_return("Brutal Helm") }
  end

  let(:record) do
    instance_double("PvpMetaItemPopularity",
      id:             1,
      item:           item,
      slot:           "HEAD",
      usage_count:    80,
      usage_pct:      55.0,
      prev_usage_pct: 40.0,
      snapshot_at:    Time.zone.parse("2026-01-01 00:00:00")
    )
  end

  subject(:result) { described_class.new(record, locale: "en_US").call }

  it "serializes all fields" do
    expect(result[:id]).to eq(1)
    expect(result[:slot]).to eq("HEAD")
    expect(result[:usage_count]).to eq(80)
    expect(result[:usage_pct]).to eq(55.0)
    expect(result[:prev_usage_pct]).to eq(40.0)
  end

  it "serializes nested item ref" do
    expect(result[:item][:id]).to eq(10)
    expect(result[:item][:blizzard_id]).to eq(99_999)
    expect(result[:item][:name]).to eq("Brutal Helm")
    expect(result[:item][:icon_url]).to eq("https://cdn.example.com/icon.jpg")
    expect(result[:item][:quality]).to eq("EPIC")
  end

  it "computes trend via TrendClassifier" do
    expect(result[:trend]).to eq("up")
  end

  context "when crafting_stats provided" do
    subject(:result) do
      described_class.new(record, locale: "en_US", crafting_stats: [ "HASTE_RATING", "CRIT_RATING" ]).call
    end

    it "sets crafted: true and top_crafting_stats" do
      expect(result[:crafted]).to be true
      expect(result[:top_crafting_stats]).to eq([ "HASTE_RATING", "CRIT_RATING" ])
    end
  end

  context "when crafting_stats is nil" do
    it "sets crafted: false and top_crafting_stats: []" do
      expect(result[:crafted]).to be false
      expect(result[:top_crafting_stats]).to eq([])
    end
  end

  context "when prev_usage_pct is nil" do
    let(:record) do
      instance_double("PvpMetaItemPopularity",
        id:             2,
        item:           item,
        slot:           "HEAD",
        usage_count:    50,
        usage_pct:      30.0,
        prev_usage_pct: nil,
        snapshot_at:    Time.zone.parse("2026-01-01 00:00:00")
      )
    end

    it "returns trend: new and prev_usage_pct: nil" do
      expect(result[:trend]).to eq("new")
      expect(result[:prev_usage_pct]).to be_nil
    end
  end
end
