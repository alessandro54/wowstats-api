# == Schema Information
#
# Table name: pvp_leaderboard_entries
# Database name: primary
#
#  id                          :bigint           not null, primary key
#  equipment_processed_at      :datetime
#  hero_talent_tree_name       :string
#  item_level                  :integer
#  losses                      :integer          default(0)
#  rank                        :integer
#  rating                      :integer
#  snapshot_at                 :datetime
#  specialization_processed_at :datetime
#  sync_retry_count            :integer          default(0), not null
#  tier_4p_active              :boolean          default(FALSE)
#  tier_set_name               :string
#  tier_set_pieces             :integer
#  wins                        :integer          default(0)
#  created_at                  :datetime         not null
#  updated_at                  :datetime         not null
#  character_id                :bigint           not null
#  hero_talent_tree_id         :integer
#  pvp_leaderboard_id          :bigint           not null
#  spec_id                     :integer
#  tier_set_id                 :integer
#
# Indexes
#
#  idx_entries_for_talent_player_count                     (pvp_leaderboard_id,spec_id,character_id) WHERE (specialization_processed_at IS NOT NULL)
#  idx_entries_top_chars_equipment                         (pvp_leaderboard_id,character_id,rating DESC) WHERE ((spec_id IS NOT NULL) AND (equipment_processed_at IS NOT NULL))
#  idx_entries_top_chars_specialization                    (pvp_leaderboard_id,character_id,rating DESC) WHERE ((spec_id IS NOT NULL) AND (specialization_processed_at IS NOT NULL))
#  idx_entries_unique_char_leaderboard                     (character_id,pvp_leaderboard_id) UNIQUE
#  index_entries_for_batch_processing                      (id,equipment_processed_at)
#  index_entries_for_spec_meta                             (pvp_leaderboard_id,spec_id,rating)
#  index_entries_on_leaderboard_and_rating                 (pvp_leaderboard_id,rating)
#  index_pvp_entries_on_character_and_equipment_processed  (character_id,equipment_processed_at) WHERE (equipment_processed_at IS NOT NULL)
#  index_pvp_leaderboard_entries_on_character_id           (character_id)
#  index_pvp_leaderboard_entries_on_hero_talent_tree_id    (hero_talent_tree_id)
#  index_pvp_leaderboard_entries_on_pvp_leaderboard_id     (pvp_leaderboard_id)
#  index_pvp_leaderboard_entries_on_rank                   (rank)
#  index_pvp_leaderboard_entries_on_tier_set_id            (tier_set_id)
#
# Foreign Keys
#
#  fk_rails_...  (character_id => characters.id)
#  fk_rails_...  (pvp_leaderboard_id => pvp_leaderboards.id)
#
require 'rails_helper'

RSpec.describe PvpLeaderboardEntry, type: :model do
  describe 'associations' do
    it { should belong_to(:pvp_leaderboard) }
    it { should belong_to(:character) }
  end

  describe '#winrate' do
    context 'with wins and losses' do
      let(:entry) { build(:pvp_leaderboard_entry, wins: 15, losses: 5) }

      it 'calculates winrate correctly' do
        expect(entry.winrate).to eq(75.0)
      end
    end

    context 'with only wins' do
      let(:entry) { build(:pvp_leaderboard_entry, wins: 20, losses: 0) }

      it 'calculates winrate correctly' do
        expect(entry.winrate).to eq(100.0)
      end
    end

    context 'with only losses' do
      let(:entry) { build(:pvp_leaderboard_entry, wins: 0, losses: 10) }

      it 'calculates winrate correctly' do
        expect(entry.winrate).to eq(0.0)
      end
    end

    context 'with no games played' do
      let(:entry) { build(:pvp_leaderboard_entry, wins: 0, losses: 0) }

      it 'returns 0.0' do
        expect(entry.winrate).to eq(0.0)
      end
    end

    context 'with nil values' do
      let(:entry) { build(:pvp_leaderboard_entry, wins: nil, losses: nil) }

      it 'handles nil values gracefully' do
        expect(entry.winrate).to eq(0.0)
      end
    end
  end

  describe 'scopes' do
    describe '.latest_snapshot_for_bracket' do
      let!(:current_season) { create(:pvp_season, is_current: true) }
      let!(:old_season)     { create(:pvp_season, is_current: false) }
      let!(:leaderboard_current) { create(:pvp_leaderboard, pvp_season: current_season, bracket: '2v2') }
      let!(:leaderboard_old)     { create(:pvp_leaderboard, pvp_season: old_season, bracket: '2v2') }
      let!(:leaderboard_3v3)     { create(:pvp_leaderboard, pvp_season: current_season, bracket: '3v3') }
      let!(:char_a) { create(:character) }
      let!(:char_b) { create(:character) }

      let!(:entry_current_processed) do
        create(:pvp_leaderboard_entry,
          character:       char_a,
          pvp_leaderboard: leaderboard_current,
          spec_id:         65)
      end

      let!(:entry_current_unprocessed) do
        create(:pvp_leaderboard_entry,
          character:       char_b,
          pvp_leaderboard: leaderboard_current,
          spec_id:         nil)
      end

      let!(:entry_old_season) do
        create(:pvp_leaderboard_entry,
          character:       char_a,
          pvp_leaderboard: leaderboard_old,
          spec_id:         65)
      end

      let!(:entry_other_bracket) do
        create(:pvp_leaderboard_entry,
          character:       char_a,
          pvp_leaderboard: leaderboard_3v3,
          spec_id:         65)
      end

      it 'returns processed entries for current season by default' do
        results = described_class.latest_snapshot_for_bracket('2v2')
        expect(results).to include(entry_current_processed)
        expect(results).not_to include(entry_current_unprocessed)
        expect(results).not_to include(entry_old_season)
        expect(results).not_to include(entry_other_bracket)
      end

      it 'returns entries for specified season' do
        results = described_class.latest_snapshot_for_bracket('2v2', season_id: old_season.id)
        expect(results).to include(entry_old_season)
        expect(results).not_to include(entry_current_processed)
      end

      it 'excludes unprocessed entries (spec_id nil)' do
        results = described_class.latest_snapshot_for_bracket('2v2')
        expect(results).not_to include(entry_current_unprocessed)
      end

      context 'when no entries have been processed' do
        before { PvpLeaderboardEntry.update_all(spec_id: nil) } # rubocop:disable Rails/SkipsModelValidations

        it 'returns no results' do
          expect(described_class.latest_snapshot_for_bracket('2v2')).to be_empty
        end
      end
    end
  end

  describe 'default values' do
    let(:entry) { create(:pvp_leaderboard_entry) }

    it 'sets default wins to 0' do
      expect(entry.wins).to eq(0)
    end

    it 'sets default losses to 0' do
      expect(entry.losses).to eq(0)
    end

    it 'sets default tier_4p_active to false' do
      expect(entry.tier_4p_active).to be false
    end
  end
end
