# == Schema Information
#
# Table name: translations
# Database name: primary
#
#  id                :bigint           not null, primary key
#  embedding         :vector(1536)
#  key               :string           not null
#  locale            :string           not null
#  meta              :jsonb            not null
#  translatable_type :string           not null
#  value             :text             not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  translatable_id   :bigint           not null
#
# Indexes
#
#  index_translations_on_key                              (key)
#  index_translations_on_locale                           (locale)
#  index_translations_on_translatable                     (translatable_type,translatable_id)
#  index_translations_on_translatable_and_locale_and_key  (translatable_type,translatable_id,locale,key) UNIQUE
#  translations_embedding_idx                             (embedding) USING ivfflat
#
require 'rails_helper'

RSpec.describe Translation, type: :model do
  describe 'associations' do
    it { should belong_to(:translatable) }
  end

  describe 'validations' do
    it { should validate_presence_of(:locale) }
    it { should validate_presence_of(:key) }
    it { should validate_presence_of(:value) }
    it { should validate_presence_of(:meta) }
  end

  describe 'database constraints' do
    it 'enforces unique translatable_type, translatable_id, locale, and key combination' do
      item = create(:item)
      create(:translation,
        translatable: item,
        locale:       'en_US',
        key:          'name'
      )

      expect {
        create(:translation,
          translatable: item,
          locale:       'en_US',
          key:          'name'
        )
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'allows same key for different locales' do
      item = create(:item)
      create(:translation,
        translatable: item,
        locale:       'en_US',
        key:          'name'
      )

      new_translation = build(:translation,
        translatable: item,
        locale:       'es_ES',
        key:          'name'
      )

      expect(new_translation).to be_valid
    end

    it 'allows same key for different translatables' do
      item1 = create(:item)
      item2 = create(:item)

      create(:translation,
        translatable: item1,
        locale:       'en_US',
        key:          'name'
      )

      new_translation = build(:translation,
        translatable: item2,
        locale:       'en_US',
        key:          'name'
      )

      expect(new_translation).to be_valid
    end
  end

  describe 'scopes' do
    let!(:translation_en) { create(:translation, locale: 'en_US', key: 'name') }
    let!(:translation_es) { create(:translation, locale: 'es_ES', key: 'name') }
    let!(:translation_fr) { create(:translation, locale: 'fr_FR', key: 'description') }

    describe '.for_locale' do
      it 'returns translations for specified locale' do
        results = described_class.for_locale('en_US')
        expect(results).to include(translation_en)
        expect(results).not_to include(translation_es)
        expect(results).not_to include(translation_fr)
      end
    end

    describe '.for_key' do
      it 'returns translations for specified key' do
        results = described_class.for_key('name')
        expect(results).to include(translation_en)
        expect(results).to include(translation_es)
        expect(results).not_to include(translation_fr)
      end
    end

    describe 'scope chaining' do
      it 'allows chaining for_locale and for_key' do
        results = described_class.for_locale('en_US').for_key('name')
        expect(results).to include(translation_en)
        expect(results).not_to include(translation_es)
        expect(results).not_to include(translation_fr)
      end
    end
  end

  describe 'attributes' do
    let(:translation) { build(:translation) }

    it 'can store locale' do
      translation.locale = 'de_DE'
      expect(translation.locale).to eq('de_DE')
    end

    it 'can store key' do
      translation.key = 'description'
      expect(translation.key).to eq('description')
    end

    it 'can store value' do
      translation.value = 'A powerful sword'
      expect(translation.value).to eq('A powerful sword')
    end

    it 'can store translatable_type' do
      translation.translatable_type = 'Item'
      expect(translation.translatable_type).to eq('Item')
    end

    it 'can store translatable_id' do
      translation.translatable_id = 123
      expect(translation.translatable_id).to eq(123)
    end
  end

  describe 'JSONB handling for meta' do
    let(:translation) { create(:translation) }

    it 'stores and retrieves meta data correctly' do
      meta_data = {
        'source' => 'blizzard_api',
        'version' => '2.0.1',
        'context' => { 'region' => 'us', 'patch' => '10.2.0' }
      }

      translation.update!(meta: meta_data)
      translation.reload

      expect(translation.meta).to eq(meta_data)
      expect(translation.meta['source']).to eq('blizzard_api')
      expect(translation.meta['context']['region']).to eq('us')
    end

    it 'handles complex nested JSON structures' do
      complex_meta = {
        'localization' => {
          'gender' => 'neutral',
          'formal' => false,
          'cultural_context' => {
            'region_specific' => true,
            'variations' => [ 'formal', 'informal' ]
          }
        },
        'metadata' => {
          'created_by' => 'system',
          'reviewed' => true,
          'tags' => [ 'pvp', 'equipment', 'weapon' ]
        }
      }

      translation.update!(meta: complex_meta)
      translation.reload

      expect(translation.meta['localization']['cultural_context']['variations']).to eq([ 'formal', 'informal' ])
      expect(translation.meta['metadata']['tags']).to include('pvp')
    end
  end

  describe 'polymorphic association' do
    let(:item) { create(:item) }
    let(:character) { create(:character) }

    it 'can associate with Item' do
      translation = create(:translation, translatable: item)
      expect(translation.translatable).to eq(item)
      expect(translation.translatable_type).to eq('Item')
    end

    it 'can associate with Character' do
      translation = create(:translation, translatable: character)
      expect(translation.translatable).to eq(character)
      expect(translation.translatable_type).to eq('Character')
    end

    it 'can find translations through polymorphic association' do
      translation = create(:translation,
        translatable: item,
        locale:       'en_US',
        key:          'name'
      )

      found_translation = item.translations.for_locale('en_US').for_key('name').first
      expect(found_translation).to eq(translation)
    end
  end

  describe 'timestamps' do
    let(:translation) { create(:translation) }

    it 'sets created_at automatically' do
      expect(translation.created_at).to be_within(5.seconds).of(Time.current)
    end

    it 'sets updated_at automatically' do
      expect(translation.updated_at).to be_within(5.seconds).of(Time.current)
    end

    it 'updates updated_at on save' do
      original_updated_at = translation.updated_at
      sleep(0.1)
      translation.update!(value: 'Updated translation')

      expect(translation.updated_at).to be > original_updated_at
    end
  end

  describe 'value field' do
    it 'can store short text' do
      translation = create(:translation, value: 'Sword')
      expect(translation.value).to eq('Sword')
    end

    it 'can store long text' do
      long_text = 'This is a very long description that contains multiple sentences and detailed ' \
                  'information about the item, including its history, properties, and usage ' \
                  'in various contexts.'
      translation = create(:translation, value: long_text)
      expect(translation.value).to eq(long_text)
    end

    it 'can store text with special characters' do
      special_text = 'Épée légendaire avec des accents et des caractères spéciaux: ñ, ü, ç, ø'
      translation = create(:translation, value: special_text)
      expect(translation.value).to eq(special_text)
    end
  end
end
