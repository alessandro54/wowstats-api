# == Schema Information
#
# Table name: pvp_meta_enchant_popularity
# Database name: primary
#
#  id                :bigint           not null, primary key
#  bracket           :string           not null
#  prev_usage_pct    :decimal(5, 2)
#  slot              :string           not null
#  snapshot_at       :datetime         not null
#  usage_count       :integer          default(0), not null
#  usage_pct         :decimal(5, 2)
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  enchantment_id    :bigint           not null
#  pvp_season_id     :bigint           not null
#  pvp_sync_cycle_id :bigint
#  spec_id           :integer          not null
#
# Indexes
#
#  idx_meta_enchant_lookup                                 (pvp_season_id,bracket,spec_id,slot)
#  idx_meta_enchant_unique_cycle                           (pvp_sync_cycle_id,bracket,spec_id,slot,enchantment_id) UNIQUE WHERE (pvp_sync_cycle_id IS NOT NULL)
#  idx_meta_enchant_unique_no_cycle                        (pvp_season_id,bracket,spec_id,slot,enchantment_id) UNIQUE WHERE (pvp_sync_cycle_id IS NULL)
#  index_pvp_meta_enchant_popularity_on_enchantment_id     (enchantment_id)
#  index_pvp_meta_enchant_popularity_on_pvp_season_id      (pvp_season_id)
#  index_pvp_meta_enchant_popularity_on_pvp_sync_cycle_id  (pvp_sync_cycle_id)
#
# Foreign Keys
#
#  fk_rails_...  (enchantment_id => enchantments.id)
#  fk_rails_...  (pvp_season_id => pvp_seasons.id)
#  fk_rails_...  (pvp_sync_cycle_id => pvp_sync_cycles.id)
#
class PvpMetaEnchantPopularity < ApplicationRecord
  include MetaPopularityScopes

  self.table_name = "pvp_meta_enchant_popularity"
  self.meta_includes = { enchantment: :translations }

  belongs_to :pvp_season
  belongs_to :enchantment
end
