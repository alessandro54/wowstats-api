require "rails_helper"

# Live Blizzard API contract checks. Skipped by default; run nightly in CI
# via RUN_CONTRACT_TESTS=1 with Blizzard credentials.
#
# Catches API-shape regressions before they reach prod sync (e.g. the
# `nodes` → `hero_talent_nodes` rename that broke hero data for weeks).
RSpec.describe "Blizzard talent-tree API contract", :contract do
  # One spec per class is enough to catch shape changes; the API returns
  # parallel structures across classes.
  SAMPLE_SPECS = {
    death_knight_unholy: 252,
    priest_holy:         257,
    warrior_arms:        71,
    mage_frost:          64,
    druid_balance:       102
  }.freeze

  before(:all) do
    creds = Rails.application.credentials.dig(:blizzard, :client_id) || ENV["BLIZZARD_CLIENT_ID"]
    skip "Blizzard credentials not configured (set BLIZZARD_CLIENT_ID/SECRET)" if creds.blank?
  end

  let(:client) { Blizzard::Client.new(region: "us", locale: "en_US") }

  describe "talent-tree index" do
    it "returns spec_talent_trees as an array of objects with key.href" do
      index = client.get("/data/wow/talent-tree/index", namespace: client.static_namespace)
      entries = index["spec_talent_trees"]

      expect(entries).to be_an(Array)
      expect(entries).not_to be_empty
      expect(entries.first).to include("key")
      expect(entries.first["key"]).to include("href")
      expect(entries.first["key"]["href"]).to match(%r{/talent-tree/\d+/playable-specialization/\d+})
    end
  end

  describe "per-spec tree response" do
    SAMPLE_SPECS.each do |label, spec_id|
      context "for #{label} (spec_id=#{spec_id})" do
        let(:tree) do
          # Find the tree_id for this spec_id from the index.
          index    = client.get("/data/wow/talent-tree/index", namespace: client.static_namespace)
          entry    = Array(index["spec_talent_trees"]).find { |e|
            e.dig("key", "href").to_s.include?("/playable-specialization/#{spec_id}")
          }
          tree_id = entry["key"]["href"].match(%r{/talent-tree/(\d+)/})[1]
          client.get("/data/wow/talent-tree/#{tree_id}/playable-specialization/#{spec_id}",
            namespace: client.static_namespace)
        end

        it "has the three required top-level keys" do
          expect(tree.keys).to include("class_talent_nodes", "spec_talent_nodes", "hero_talent_trees")
        end

        it "has non-empty class_talent_nodes" do
          expect(Array(tree["class_talent_nodes"])).not_to be_empty
        end

        it "has non-empty spec_talent_nodes" do
          expect(Array(tree["spec_talent_nodes"])).not_to be_empty
        end

        it "has hero_talent_trees with hero_talent_nodes inside (current Blizzard shape)" do
          hero_trees = Array(tree["hero_talent_trees"])
          expect(hero_trees).not_to be_empty
          expect(hero_trees).to all(have_key("hero_talent_nodes"))
          # At least one hero tree must have non-empty nodes — otherwise the sync
          # would silently produce zero hero rows.
          total_hero_nodes = hero_trees.sum { |h| Array(h["hero_talent_nodes"]).size }
          expect(total_hero_nodes).to be > 0
        end

        it "has the expected node shape (id, ranks)" do
          first_node = Array(tree["class_talent_nodes"]).first
          expect(first_node).to include("id", "ranks")
          expect(Array(first_node["ranks"])).not_to be_empty
        end
      end
    end
  end
end
