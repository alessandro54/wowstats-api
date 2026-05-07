# == Schema Information
#
# Table name: items
# Database name: primary
#
#  id                :bigint           not null, primary key
#  icon_url          :string
#  inventory_type    :string
#  item_class        :string
#  item_subclass     :string
#  meta_synced_at    :datetime
#  quality           :string
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  blizzard_id       :bigint           not null
#  blizzard_media_id :bigint
#
# Indexes
#
#  index_items_on_blizzard_id  (blizzard_id) UNIQUE
#
require 'rails_helper'

RSpec.describe Item, type: :model do
  describe 'associations' do
    it { should have_many(:character_items).dependent(:destroy) }
    it { should have_many(:characters).through(:character_items) }
  end

  describe 'validations' do
    subject { build(:item) }
    it { should validate_presence_of(:blizzard_id) }
    it { should validate_uniqueness_of(:blizzard_id) }
  end

  describe 'included modules' do
    it 'includes Translatable module' do
      expect(described_class.included_modules).to include(Translatable)
    end
  end

  describe '#meta_synced?' do
    context 'when meta_synced_at is recent' do
      let(:item) { build(:item, icon_url: "https://example.com/icon.jpg", meta_synced_at: 3.days.ago) }

      it 'returns true' do
        expect(item.meta_synced?).to be true
      end
    end

    context 'when meta_synced_at is old' do
      let(:item) { build(:item, meta_synced_at: 2.weeks.ago) }

      it 'returns false' do
        expect(item.meta_synced?).to be false
      end
    end

    context 'when meta_synced_at is nil' do
      let(:item) { build(:item, meta_synced_at: nil) }

      it 'returns false' do
        expect(item.meta_synced?).to be false
      end
    end
  end
end
