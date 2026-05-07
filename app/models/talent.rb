# == Schema Information
#
# Table name: talents
# Database name: primary
#
#  id          :bigint           not null, primary key
#  display_col :integer
#  display_row :integer
#  icon_url    :string
#  max_rank    :integer          default(1), not null
#  talent_type :string           not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  blizzard_id :bigint           not null
#  node_id     :bigint
#  spell_id    :integer
#
# Indexes
#
#  index_talents_on_blizzard_id  (blizzard_id) UNIQUE
#  index_talents_on_node_id      (node_id)
#
class Talent < ApplicationRecord
  include Translatable

  has_many :character_talents,       dependent: :restrict_with_exception
  has_many :talent_spec_assignments, dependent: :destroy

  validates :blizzard_id, presence: true, uniqueness: true
  validates :talent_type, presence: true, inclusion: { in: %w[class spec hero pvp] }
end
