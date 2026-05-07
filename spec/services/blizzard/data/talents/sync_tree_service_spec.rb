require "rails_helper"

RSpec.describe Blizzard::Data::Talents::SyncTreeService, type: :service do
  let(:client_double) { instance_double(Blizzard::Client) }

  subject(:service) { described_class.new(region: "us", locale: "en_US") }

  before do
    allow(Blizzard::Client).to receive(:new).and_return(client_double)
    allow(SyncTalentMediaJob).to receive(:perform_later)
  end

  describe "#apply_prerequisites (private)" do
    let(:edges) { Set.new([ [ 101, 100 ], [ 102, 101 ] ]) }

    before do
      TalentPrerequisite.create!(node_id: 999, prerequisite_node_id: 998)
    end

    it "rolls back delete when insert_all! raises" do
      allow(TalentPrerequisite).to receive(:insert_all!).and_raise(ActiveRecord::StatementInvalid, "simulated")

      expect {
        service.send(:apply_prerequisites, edges)
      }.to raise_error(ActiveRecord::StatementInvalid)

      expect(TalentPrerequisite.where(node_id: 999).count).to eq(1)
    end
  end

  describe "#apply_spec_assignments (private)" do
    it "rolls back delete when insert_all raises (per-spec transaction)" do
      existing_talent = create(:talent, blizzard_id: 50_001, talent_type: "class")
      TalentSpecAssignment.create!(talent: existing_talent, spec_id: 1, default_points: 0)

      create(:talent, blizzard_id: 50_002, talent_type: "class")
      spec_assignments = { 1 => { "class" => Set.new([ 50_002 ]) } }

      allow(TalentSpecAssignment).to receive(:insert_all).and_raise(ActiveRecord::StatementInvalid, "simulated")

      expect {
        service.send(:apply_spec_assignments, spec_assignments)
      }.to raise_error(ActiveRecord::StatementInvalid)

      expect(TalentSpecAssignment.where(spec_id: 1, talent_id: existing_talent.id).count).to eq(1)
    end

    it "preserves TSAs of talent_types absent from the current sync" do
      hero_talent  = create(:talent, blizzard_id: 60_001, talent_type: "hero")
      class_talent = create(:talent, blizzard_id: 60_002, talent_type: "class")
      TalentSpecAssignment.create!(talent: hero_talent,  spec_id: 5, default_points: 0)
      TalentSpecAssignment.create!(talent: class_talent, spec_id: 5, default_points: 0)

      new_class_talent = create(:talent, blizzard_id: 60_003, talent_type: "class")
      spec_assignments = { 5 => { "class" => Set.new([ 60_003 ]) } }

      service.send(:apply_spec_assignments, spec_assignments)

      expect(TalentSpecAssignment.where(spec_id: 5, talent_id: hero_talent.id).count).to eq(1)
      expect(TalentSpecAssignment.where(spec_id: 5, talent_id: class_talent.id).count).to eq(0)
      expect(TalentSpecAssignment.where(spec_id: 5, talent_id: new_class_talent.id).count).to eq(1)
    end

    it "deletes stale TSAs of talent_types that ARE present in the sync" do
      stale_class = create(:talent, blizzard_id: 70_001, talent_type: "class")
      TalentSpecAssignment.create!(talent: stale_class, spec_id: 6, default_points: 0)

      kept_class = create(:talent, blizzard_id: 70_002, talent_type: "class")
      spec_assignments = { 6 => { "class" => Set.new([ 70_002 ]) } }

      service.send(:apply_spec_assignments, spec_assignments)

      expect(TalentSpecAssignment.where(spec_id: 6, talent_id: stale_class.id).count).to eq(0)
      expect(TalentSpecAssignment.where(spec_id: 6, talent_id: kept_class.id).count).to eq(1)
    end
  end

  describe "#apply_talent_types (private)" do
    it "does not downgrade a talent already classified as hero" do
      talent = create(:talent, blizzard_id: 99_001, talent_type: "hero")
      talent_attrs = { 99_001 => { talent_type: "class", node_id: 1, display_row: 1, display_col: 1, max_rank: 1,
spell_id: nil } }

      service.send(:apply_talent_types, talent_attrs)

      expect(talent.reload.talent_type).to eq("hero")
    end

    it "corrects a class talent to spec" do
      talent = create(:talent, blizzard_id: 99_002, talent_type: "class")
      talent_attrs = { 99_002 => { talent_type: "spec", node_id: 1, display_row: 1, display_col: 1, max_rank: 1,
spell_id: nil } }

      service.send(:apply_talent_types, talent_attrs)

      expect(talent.reload.talent_type).to eq("spec")
    end
  end

  describe "talent_type priority in process_nodes (private)" do
    it "hero wins over class when same blizzard_id appears in both sections" do
      talent_attrs = {}
      edges        = Set.new
      ids          = Set.new
      name_map     = {}

      rank = { "tooltip" => { "talent" => { "id" => 500, "name" => "Halo" },
                              "spell_tooltip" => { "spell" => { "id" => 1 } } } }
      class_node = { "id" => 1, "display_row" => 1, "display_col" => 1, "ranks" => [ rank ] }
      hero_node  = { "id" => 2, "display_row" => 2, "display_col" => 2, "ranks" => [ rank ] }

      service.send(:process_nodes, [ class_node ], "class", talent_attrs, edges, ids, name_map)
      service.send(:process_nodes, [ hero_node ],  "hero",  talent_attrs, edges, ids, name_map)

      expect(talent_attrs[500][:talent_type]).to eq("hero")
    end

    it "hero is not overwritten when class is processed after hero" do
      talent_attrs = {}
      edges        = Set.new
      ids          = Set.new
      name_map     = {}

      rank = { "tooltip" => { "talent" => { "id" => 501, "name" => "Halo" },
                              "spell_tooltip" => { "spell" => { "id" => 2 } } } }
      hero_node  = { "id" => 2, "display_row" => 2, "display_col" => 2, "ranks" => [ rank ] }
      class_node = { "id" => 1, "display_row" => 1, "display_col" => 1, "ranks" => [ rank ] }

      service.send(:process_nodes, [ hero_node ],  "hero",  talent_attrs, edges, ids, name_map)
      service.send(:process_nodes, [ class_node ], "class", talent_attrs, edges, ids, name_map)

      expect(talent_attrs[501][:talent_type]).to eq("hero")
    end
  end

  describe "process_tree (private) — Blizzard hero key compatibility" do
    it "reads hero nodes from hero_talent_nodes (current Blizzard shape)" do
      talent_attrs = {}
      edges        = Set.new
      assignments  = Hash.new { |h, k| h[k] = Set.new }
      name_map     = {}

      rank      = { "tooltip" => { "talent" => { "id" => 800, "name" => "Vampiric Strike" },
                                   "spell_tooltip" => { "spell" => { "id" => 99 } } } }
      hero_node = { "id" => 9, "display_row" => 1, "display_col" => 1, "ranks" => [ rank ] }
      tree      = { "class_talent_nodes" => [],
                    "spec_talent_nodes" => [],
                    "hero_talent_trees" => [
                      { "id" => 31, "name" => "San'layn", "hero_talent_nodes" => [ hero_node ] }
                    ] }

      service.send(:process_tree, tree, talent_attrs, edges, assignments, name_map, spec_id: 252)

      expect(talent_attrs[800][:talent_type]).to eq("hero")
      expect(assignments["hero"]).to include(800)
    end

    it "does not register hero bucket when hero_talent_nodes is empty" do
      talent_attrs = {}
      edges        = Set.new
      assignments  = Hash.new { |h, k| h[k] = Hash.new { |hh, kk| hh[kk] = Set.new } }
      name_map     = {}

      tree = { "class_talent_nodes" => [],
               "spec_talent_nodes" => [],
               "hero_talent_trees" => [
                 { "id" => 31, "name" => "Empty", "hero_talent_nodes" => [] }
               ] }

      service.send(:process_tree, tree, talent_attrs, edges, assignments[5], name_map, spec_id: 5)

      # Crucial: hero key must NOT be registered, otherwise apply_spec_assignments
      # would treat hero as a "seen" type and wipe every existing hero TSA.
      expect(assignments[5].key?("hero")).to be(false)
    end

    it "falls back to nodes (legacy Blizzard shape) when hero_talent_nodes is absent" do
      talent_attrs = {}
      edges        = Set.new
      assignments  = Hash.new { |h, k| h[k] = Set.new }
      name_map     = {}

      rank      = { "tooltip" => { "talent" => { "id" => 801, "name" => "Old Hero" },
                                   "spell_tooltip" => { "spell" => { "id" => 100 } } } }
      hero_node = { "id" => 10, "display_row" => 1, "display_col" => 1, "ranks" => [ rank ] }
      tree      = { "class_talent_nodes" => [],
                    "spec_talent_nodes" => [],
                    "hero_talent_trees" => [
                      { "id" => 32, "name" => "Legacy", "nodes" => [ hero_node ] }
                    ] }

      service.send(:process_tree, tree, talent_attrs, edges, assignments, name_map, spec_id: 252)

      expect(talent_attrs[801][:talent_type]).to eq("hero")
    end
  end

  describe "#validate_tree_response! (private)" do
    it "rejects responses missing top-level keys" do
      tree = { "class_talent_nodes" => [], "spec_talent_nodes" => [] } # missing hero_talent_trees
      allow(Sentry).to receive(:capture_message)

      expect(service.send(:validate_tree_response!, tree, 71)).to be(false)
      expect(Sentry).to have_received(:capture_message)
        .with("SyncTreeService schema regression", hash_including(level: :warning))
    end

    it "accepts responses with all required keys (even if arrays are empty)" do
      tree = { "class_talent_nodes" => [], "spec_talent_nodes" => [], "hero_talent_trees" => [] }
      expect(service.send(:validate_tree_response!, tree, 71)).to be(true)
    end

    it "rejects non-Hash responses" do
      expect(service.send(:validate_tree_response!, nil, 71)).to be(false)
      expect(service.send(:validate_tree_response!, [], 71)).to be(false)
    end
  end

  describe "#detect_regression (private)" do
    let(:region) { "us" }

    before { service.instance_variable_set(:@region, region) }

    it "flags when a talent_type falls below the absolute floor" do
      counts = { "class" => 1000, "spec" => 1000, "hero" => 5 }

      result = service.send(:detect_regression, counts)

      expect(result[:detected]).to be(true)
      expect(result[:details].first).to include(type: "hero", reason: "below_floor")
    end

    it "flags when a talent_type drops below the ratio threshold vs prior success" do
      TalentSyncRun.create!(region: region, locale: "en_US", force: false, status: "success",
        started_at: 1.hour.ago, completed_at: 30.minutes.ago,
        counts: { "class" => 1000, "spec" => 3000, "hero" => 700 })
      counts = { "class" => 1000, "spec" => 3000, "hero" => 200 } # 200/700 ≈ 0.28 < 0.5

      result = service.send(:detect_regression, counts)

      expect(result[:detected]).to be(true)
      expect(result[:details].first).to include(type: "hero", reason: "ratio_drop")
    end

    it "does not flag when counts hold steady" do
      TalentSyncRun.create!(region: region, locale: "en_US", force: false, status: "success",
        started_at: 1.hour.ago, completed_at: 30.minutes.ago,
        counts: { "class" => 1000, "spec" => 3000, "hero" => 700 })
      counts = { "class" => 1000, "spec" => 3000, "hero" => 700 }

      expect(service.send(:detect_regression, counts)[:detected]).to be(false)
    end

    it "does not compare ratios when no baseline exists, only floors" do
      counts = { "class" => 1000, "spec" => 3000, "hero" => 700 }
      expect(service.send(:detect_regression, counts)[:detected]).to be(false)
    end
  end

  describe "#call full flow with regression guard" do
    let(:valid_tree) do
      rank = { "tooltip" => { "talent" => { "id" => 600, "name" => "Halo" },
                              "spell_tooltip" => { "spell" => { "id" => 1 } } } }
      class_node = { "id" => 1, "display_row" => 1, "display_col" => 1, "ranks" => [ rank ] }
      { "class_talent_nodes" => [ class_node ],
        "spec_talent_nodes" => [],
        "hero_talent_trees" => [] }
    end

    before do
      allow(client_double).to receive(:static_namespace).and_return("static-us")
      allow(client_double).to receive(:locale).and_return("en_US")
      allow(client_double).to receive(:get)
        .with("/data/wow/talent-tree/index", anything)
        .and_return({ "spec_talent_trees" => [
          { "key" => { "href" => "https://us.api.blizzard.com/data/wow/talent-tree/786/" \
                                  "playable-specialization/71?namespace=static-us" } }
        ] })
      allow(client_double).to receive(:get)
        .with("/data/wow/talent-tree/786/playable-specialization/71", anything)
        .and_return(valid_tree)
      allow(Sentry).to receive(:capture_message)
    end

    it "creates a TalentSyncRun, persists counts, and marks aborted_regression on collapse" do
      result = service.call

      expect(result.success?).to be(false)
      run = TalentSyncRun.recent.first
      expect(run.status).to eq("aborted_regression")
      expect(run.regression["detected"]).to be(true)
      expect(run.counts).to include("class" => 1)
      expect(run.completed_at).to be_present
    end

    it "force: true bypasses regression guard and finalizes as success" do
      force_service = described_class.new(region: "us", locale: "en_US", force: true)
      force_service.call

      run = TalentSyncRun.recent.first
      expect(run.status).to eq("success")
      expect(run.force).to be(true)
    end
  end

  describe "#call with a failing spec" do
    let(:empty_tree) { { "class_talent_nodes" => [], "spec_talent_nodes" => [], "hero_talent_trees" => [] } }

    before do
      allow(client_double).to receive(:static_namespace).and_return("static-us")
      allow(client_double).to receive(:locale).and_return("en_US")

      allow(client_double).to receive(:get)
        .with("/data/wow/talent-tree/index", anything)
        .and_return({
          "spec_talent_trees" => [
            { "key" => { "href" => "https://us.api.blizzard.com/data/wow/talent-tree/786/" \
                                    "playable-specialization/71?namespace=static-us" } },
            { "key" => { "href" => "https://us.api.blizzard.com/data/wow/talent-tree/787/" \
                                    "playable-specialization/72?namespace=static-us" } }
          ]
        })

      allow(client_double).to receive(:get)
        .with("/data/wow/talent-tree/786/playable-specialization/71", anything)
        .and_return(empty_tree)

      allow(client_double).to receive(:get)
        .with("/data/wow/talent-tree/787/playable-specialization/72", anything)
        .and_raise(Blizzard::Client::Error, "timeout")
    end

    it "does not call apply_prerequisites when any spec fails" do
      expect(service).not_to receive(:apply_prerequisites)
      service.call
    end

    it "preserves existing spec assignments for the failed spec" do
      talent = create(:talent, blizzard_id: 10_001)
      TalentSpecAssignment.create!(talent: talent, spec_id: 72, default_points: 0)

      service.call

      expect(TalentSpecAssignment.where(spec_id: 72).count).to eq(1)
    end

    it "does not enqueue SyncTalentMediaJob on non-force sync" do
      expect(SyncTalentMediaJob).not_to receive(:perform_later)
      service.call
    end

    it "enqueues SyncTalentMediaJob when force: true" do
      force_service = described_class.new(region: "us", locale: "en_US", force: true)
      expect(SyncTalentMediaJob).to receive(:perform_later).with(region: "us", locale: "en_US")
      force_service.call
    end
  end
end
