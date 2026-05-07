require "rails_helper"

RSpec.describe Pvp::Meta::TalentAggregationService, type: :service do
  # Tier classification moved into Pvp::Meta::TalentTierClassifier; the
  # service now delegates to it. The behavioural specs below still target
  # the same private helpers — just on the classifier instance.
  describe "#assign_tree_tiers (private)" do
    let(:talent_info) do
      {
        1 => { node_id: 101, max_rank: 1, default_points: 0 },
        2 => { node_id: 102, max_rank: 1, default_points: 0 },
        3 => { node_id: 103, max_rank: 1, default_points: 0 },
        4 => { node_id: 104, max_rank: 2, default_points: 0 } # multi-rank (apex-style) node
      }
    end

    subject(:service) do
      Pvp::Meta::TalentTierClassifier.new(rows: [], prereqs: {}, talent_info: talent_info)
    end

    THRESHOLD = Pvp::Meta::TalentTierClassifier::SITUATIONAL_THRESHOLD

    def row(talent_id:, in_top_build:, usage_pct:)
      { "talent_id" => talent_id, "in_top_build" => in_top_build,
        "usage_pct" => usage_pct, "tier" => "common" }
    end

    it "marks in_top_build nodes as bis" do
      r = row(talent_id: 1, in_top_build: true, usage_pct: 90.0)
      service.send(:assign_tree_tiers, { 101 => [ r ] }, 34)
      expect(r["tier"]).to eq("bis")
    end

    it "marks non-top-build nodes with pct >= threshold as situational" do
      r = row(talent_id: 2, in_top_build: false, usage_pct: THRESHOLD + 5)
      service.send(:assign_tree_tiers, { 102 => [ r ] }, 34)
      expect(r["tier"]).to eq("situational")
    end

    it "marks non-top-build nodes with pct below threshold as common" do
      r = row(talent_id: 3, in_top_build: false, usage_pct: THRESHOLD - 5)
      service.send(:assign_tree_tiers, { 103 => [ r ] }, 34)
      expect(r["tier"]).to eq("common")
    end

    it "caps BIS at budget — highest-usage in_top_build node wins, overflow node is demoted" do
      r1 = row(talent_id: 1, in_top_build: true, usage_pct: 90.0)
      r2 = row(talent_id: 2, in_top_build: true, usage_pct: 30.0)
      # budget=1 fits exactly one max_rank=1 node → highest-usage wins
      service.send(:assign_tree_tiers, { 101 => [ r1 ], 102 => [ r2 ] }, 1)
      expect(r1["tier"]).to eq("bis")
      expect(r2["tier"]).to eq("common")
    end

    it "overflow in_top_build node with usage >= relative_min is situational" do
      r1 = row(talent_id: 1, in_top_build: true, usage_pct: 90.0)
      r2 = row(talent_id: 2, in_top_build: true, usage_pct: 70.0)
      # budget=1 → r1 BIS (90%), r2 overflows; relative_min = 90*0.5 = 45; 70 >= 45 → situational
      service.send(:assign_tree_tiers, { 101 => [ r1 ], 102 => [ r2 ] }, 1)
      expect(r1["tier"]).to eq("bis")
      expect(r2["tier"]).to eq("situational")
    end

    it "non-BIS node far below lowest-BIS confidence is common even if above absolute threshold" do
      r1 = row(talent_id: 1, in_top_build: true, usage_pct: 90.0)
      r2 = row(talent_id: 2, in_top_build: false, usage_pct: 15.0)
      # relative_min = 90*0.5 = 45; 15 < 45 → common (would be situational with old absolute threshold)
      service.send(:assign_tree_tiers, { 101 => [ r1 ], 102 => [ r2 ] }, 34)
      expect(r1["tier"]).to eq("bis")
      expect(r2["tier"]).to eq("common")
    end

    it "non-BIS node close to lowest-BIS confidence is situational" do
      r1 = row(talent_id: 1, in_top_build: true, usage_pct: 42.0)
      r2 = row(talent_id: 2, in_top_build: false, usage_pct: 35.0)
      # relative_min = 42*0.5 = 21; 35 >= 21 → situational
      service.send(:assign_tree_tiers, { 101 => [ r1 ], 102 => [ r2 ] }, 34)
      expect(r1["tier"]).to eq("bis")
      expect(r2["tier"]).to eq("situational")
    end

    it "multi-rank node (max_rank=2) skipped when cost exceeds remaining budget" do
      r = row(talent_id: 4, in_top_build: true, usage_pct: 90.0)
      # node 104 costs 2 pts, budget=1 → can't fit → Jenks fallback → situational (90% > THRESHOLD)
      service.send(:assign_tree_tiers, { 104 => [ r ] }, 1)
      expect(r["tier"]).to eq("situational")
    end

    it "budget=0 forces all in_top_build nodes through Jenks" do
      r1 = row(talent_id: 1, in_top_build: true, usage_pct: 90.0)
      r2 = row(talent_id: 2, in_top_build: true, usage_pct: 80.0)
      # no budget → bis_nodes empty → both above SITUATIONAL_THRESHOLD → situational
      service.send(:assign_tree_tiers, { 101 => [ r1 ], 102 => [ r2 ] }, 0)
      expect(r1["tier"]).to eq("situational")
      expect(r2["tier"]).to eq("situational")
    end

    it "all in_top_build nodes fit exactly within budget — all BIS" do
      r1 = row(talent_id: 1, in_top_build: true, usage_pct: 90.0)
      r2 = row(talent_id: 2, in_top_build: true, usage_pct: 80.0)
      # budget=2, each node costs 1 → both fit
      service.send(:assign_tree_tiers, { 101 => [ r1 ], 102 => [ r2 ] }, 2)
      expect(r1["tier"]).to eq("bis")
      expect(r2["tier"]).to eq("bis")
    end

    context "contested choice node (two talents at same node)" do
      before do
        # Override: both talent_id 1 and 2 share node 101
        service.instance_variable_set(:@talent_info, {
          1 => { node_id: 101, max_rank: 1, default_points: 0 },
          2 => { node_id: 101, max_rank: 1, default_points: 0 }
        })
        service.instance_variable_set(:@talent_names, { 1 => "Blackjack", 2 => "Tricks of the Trade" })
      end

      it "54/42 split — both become situational (node required, choice is flex)" do
        r1 = row(talent_id: 1, in_top_build: true, usage_pct: 54.0)
        r2 = row(talent_id: 2, in_top_build: false, usage_pct: 42.2)
        service.send(:assign_tree_tiers, { 101 => [ r1, r2 ] }, 34)
        expect(r1["tier"]).to eq("situational")
        expect(r2["tier"]).to eq("situational")
      end

      it "90/10 split — primary stays BIS, minor alt demoted to common" do
        r1 = row(talent_id: 1, in_top_build: true, usage_pct: 90.0)
        r2 = row(talent_id: 2, in_top_build: false, usage_pct: 10.0)
        service.send(:assign_tree_tiers, { 101 => [ r1, r2 ] }, 34)
        expect(r1["tier"]).to eq("bis")
        expect(r2["tier"]).to eq("common")
      end
    end
  end

  describe "#assign_tier_to_node (private)" do
    let(:talent_info) do
      {
        10 => { node_id: 200, max_rank: 1, default_points: 0 },
        11 => { node_id: 200, max_rank: 1, default_points: 0 }
      }
    end
    let(:talent_names) { { 10 => "Dark Dance", 11 => "Secret Step" } }

    subject(:service) do
      Pvp::Meta::TalentTierClassifier.new(
        rows:         [],
        prereqs:      {},
        talent_info:  talent_info,
        talent_names: talent_names
      )
    end

    def choice_row(talent_id:, usage_pct:)
      { "talent_id" => talent_id, "usage_pct" => usage_pct, "tier" => "common",
        "in_top_build" => false }
    end

    it "clear winner (gap > 30) — primary stays BIS, alt demoted to common" do
      r1 = choice_row(talent_id: 10, usage_pct: 90.0)
      r2 = choice_row(talent_id: 11, usage_pct: 10.0)
      service.send(:assign_tier_to_node, [ r1, r2 ], "bis")
      expect(r1["tier"]).to eq("bis")
      expect(r2["tier"]).to eq("common")
    end

    it "contested (gap <= 30) — both become situational, node is required but choice is flex" do
      r1 = choice_row(talent_id: 10, usage_pct: 60.0)
      r2 = choice_row(talent_id: 11, usage_pct: 40.0)
      service.send(:assign_tier_to_node, [ r1, r2 ], "bis")
      expect(r1["tier"]).to eq("situational")
      expect(r2["tier"]).to eq("situational")
    end

    it "exact 50-50 split — both situational" do
      r1 = choice_row(talent_id: 10, usage_pct: 50.0)
      r2 = choice_row(talent_id: 11, usage_pct: 50.0)
      service.send(:assign_tier_to_node, [ r1, r2 ], "bis")
      expect(r1["tier"]).to eq("situational")
      expect(r2["tier"]).to eq("situational")
    end

    it "contested on overflow node (tier=situational) — both stay situational" do
      # Real-world case: budget overflow pushes a contested choice node to situational tier.
      # Both talents on the same node should remain situational (not demote alt to common).
      r1 = choice_row(talent_id: 10, usage_pct: 54.0)
      r2 = choice_row(talent_id: 11, usage_pct: 42.0)
      service.send(:assign_tier_to_node, [ r1, r2 ], "situational")
      expect(r1["tier"]).to eq("situational")
      expect(r2["tier"]).to eq("situational")
    end

    it "clear winner on situational node — alt demoted to common" do
      r1 = choice_row(talent_id: 10, usage_pct: 90.0)
      r2 = choice_row(talent_id: 11, usage_pct: 10.0)
      service.send(:assign_tier_to_node, [ r1, r2 ], "situational")
      expect(r1["tier"]).to eq("situational")
      expect(r2["tier"]).to eq("common")
    end
  end

  describe "#merge_ranked_rows (private)" do
    subject(:service) { described_class.new(season: create(:pvp_season)) }

    it "uses max top_build_rank across variants so post-patch ranks display correctly" do
      # Two rank variants for the same node/name:
      # old variant (rank 2, pre-patch) and new variant (rank 4, post-patch).
      # Both in_top_build. Correct merged result should reflect rank 4.
      talent_a = create(:talent, blizzard_id: 55_001, node_id: 9_001, talent_type: "spec")
      talent_b = create(:talent, blizzard_id: 55_002, node_id: 9_001, talent_type: "spec")

      talent_a.set_translation("name", "en_US", "Charged Blast", meta: { "source" => "test" })
      talent_b.set_translation("name", "en_US", "Charged Blast", meta: { "source" => "test" })

      now = Time.current.iso8601

      rows = [
        { "talent_id" => talent_a.id, "bracket" => "2v2", "spec_id" => 71,
          "in_top_build" => true, "top_build_rank" => 2, "usage_pct" => 30.0,
          "usage_count" => 30, "tier" => "bis", "snapshot_at" => now, "default_points" => 0 },
        { "talent_id" => talent_b.id, "bracket" => "2v2", "spec_id" => 71,
          "in_top_build" => true, "top_build_rank" => 4, "usage_pct" => 70.0,
          "usage_count" => 70, "tier" => "bis", "snapshot_at" => now, "default_points" => 0 }
      ]

      merged = service.send(:merge_ranked_rows, rows)

      expect(merged.size).to eq(1)
      expect(merged.first["top_build_rank"]).to eq(4)
    end
  end
end
