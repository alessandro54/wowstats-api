# == Schema Information
#
# Table name: pvp_meta_gem_popularity
# Database name: primary
#
#  id                :bigint           not null, primary key
#  bracket           :string           not null
#  prev_usage_pct    :decimal(5, 2)
#  slot              :string           not null
#  snapshot_at       :datetime         not null
#  socket_type       :string           not null
#  usage_count       :integer          default(0), not null
#  usage_pct         :decimal(5, 2)
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  item_id           :bigint           not null
#  pvp_season_id     :bigint           not null
#  pvp_sync_cycle_id :bigint
#  spec_id           :integer          not null
#
# Indexes
#
#  idx_meta_gem_lookup                                 (pvp_season_id,bracket,spec_id,slot)
#  idx_meta_gem_unique_cycle                           (pvp_sync_cycle_id,bracket,spec_id,slot,socket_type,item_id) UNIQUE WHERE (pvp_sync_cycle_id IS NOT NULL)
#  idx_meta_gem_unique_no_cycle                        (pvp_season_id,bracket,spec_id,slot,socket_type,item_id) UNIQUE WHERE (pvp_sync_cycle_id IS NULL)
#  index_pvp_meta_gem_popularity_on_item_id            (item_id)
#  index_pvp_meta_gem_popularity_on_pvp_season_id      (pvp_season_id)
#  index_pvp_meta_gem_popularity_on_pvp_sync_cycle_id  (pvp_sync_cycle_id)
#
# Foreign Keys
#
#  fk_rails_...  (item_id => items.id)
#  fk_rails_...  (pvp_season_id => pvp_seasons.id)
#  fk_rails_...  (pvp_sync_cycle_id => pvp_sync_cycles.id)
#
class PvpMetaGemPopularity < ApplicationRecord
  include MetaPopularityScopes

  self.table_name = "pvp_meta_gem_popularity"
  self.meta_includes = { item: :translations }

  belongs_to :pvp_season
  belongs_to :item
end
