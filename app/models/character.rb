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
class Character < ApplicationRecord
  has_many :character_talents, dependent: :delete_all
  has_many :talents, through: :character_talents
  has_many :character_items, dependent: :delete_all
  has_many :items, through: :character_items

  has_many :pvp_leaderboard_entries, dependent: :delete_all

  validates :name, :realm, :region, presence: true
  validates :name, uniqueness: { scope: %i[realm region] }

  validates :blizzard_id,
            uniqueness:   { scope: :region },
            numericality: { only_integer: true }

  enum :faction, {
    alliance: 0,
    horde:    1
  }

  self.filter_attributes += [ :spec_equipment_fingerprints ]

  def print_loadout          = Character::LoadoutPrinter.call(self)
  def print_talents          = Character::TalentPrinter.call(self)
  def print_sync_status      = Character::SyncStatusPrinter.call(self)
  def print_tree(spec_id: nil) = Character::TalentTreePrinter.call(self, spec_id: spec_id)

  def self.like_name(query)
    where("name ILIKE :q", q: "%#{query}%")
  end

  def enqueue_sync_meta_job
    return if meta_synced?

    Characters::SyncCharacterJob.perform_later(
      region:,
      realm:,
      name:
    )
  end

  def display_name
    "#{name.capitalize}-#{realm.capitalize}"
  end

  def spec
    spec_id = pvp_leaderboard_entries
      .where.not(spec_id: nil)
      .order(snapshot_at: :desc)
      .pick(:spec_id)

    return nil unless spec_id

    "#{Wow::Specs.slug_for(spec_id)} #{class_slug}".titleize
  end

  def meta_synced?
    meta_synced_at&.> 1.week.ago
  end
end
