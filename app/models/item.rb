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
class Item < ApplicationRecord
  include Translatable

  has_many :character_items, dependent: :destroy
  has_many :characters, through: :character_items

  validates :blizzard_id, presence: true, uniqueness: true

  def meta_synced?
    icon_url.present? && meta_synced_at.present? && meta_synced_at > Pvp::SyncConfig::META_TTL.ago
  end
end
