# == Schema Information
#
# Table name: characters
# Database name: primary
#
#  id                          :bigint           not null, primary key
#  avatar_url                  :string
#  class_slug                  :string
#  equipment_last_modified     :datetime
#  faction                     :integer
#  inset_url                   :string
#  is_private                  :boolean          default(FALSE)
#  last_equipment_snapshot_at  :datetime
#  main_raw_url                :string
#  meta_synced_at              :datetime
#  name                        :string
#  race                        :string
#  realm                       :string
#  region                      :string
#  spec_equipment_fingerprints :jsonb
#  spec_talent_loadout_codes   :jsonb
#  stat_pcts                   :jsonb
#  talents_last_modified       :datetime
#  unavailable_until           :datetime
#  created_at                  :datetime         not null
#  updated_at                  :datetime         not null
#  blizzard_id                 :bigint
#  class_id                    :bigint
#  race_id                     :integer
#
# Indexes
#
#  index_characters_on_blizzard_id_and_region     (blizzard_id,region) UNIQUE
#  index_characters_on_is_private                 (is_private) WHERE (is_private = true)
#  index_characters_on_name_and_realm_and_region  (name,realm,region)
#  index_characters_on_stat_pcts                  (stat_pcts) USING gin
#  index_characters_on_unavailable_until_active   (unavailable_until) WHERE (unavailable_until IS NOT NULL)
#
require 'rails_helper'

RSpec.describe Character, type: :model do
  describe "validations" do
    subject { create(:character) }

    include_examples "validates presence of", :name
    include_examples "validates presence of", :realm
    include_examples "validates presence of", :region
    include_examples "validates uniqueness of", :name, scoped_to: %i[realm region]
    include_examples "validates uniqueness of", :blizzard_id, scoped_to: :region, case_insensitive: true
    include_examples "validates numericality of", :blizzard_id, only_integer: true
  end

  describe "#display_name" do
    subject { create(:character, name: "Foo", realm: "Bar", region: "eu") }

    it "returns the character's name and realm" do
        expect(subject.display_name).to eq("Foo-Bar")
      end
  end
end
