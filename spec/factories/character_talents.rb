# == Schema Information
#
# Table name: character_talents
# Database name: primary
#
#  id           :bigint           not null, primary key
#  rank         :integer          default(1)
#  slot_number  :integer
#  talent_type  :string           not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  character_id :bigint           not null
#  spec_id      :integer          not null
#  talent_id    :bigint           not null
#
# Indexes
#
#  idx_character_talents_covering_for_agg     (character_id,spec_id) WHERE (rank > 0)
#  idx_character_talents_on_char_and_type     (character_id,talent_type)
#  idx_character_talents_on_char_spec         (character_id,spec_id)
#  idx_character_talents_on_char_talent_spec  (character_id,talent_id,spec_id) UNIQUE
#  idx_character_talents_spec_type_talent     (spec_id,talent_type,talent_id)
#  index_character_talents_on_talent_id       (talent_id)
#
# Foreign Keys
#
#  fk_rails_...  (character_id => characters.id)
#  fk_rails_...  (talent_id => talents.id)
#
FactoryBot.define do
  factory :character_talent do
    association :character
    association :talent
    talent_type { talent.talent_type }
    rank        { 1 }
    slot_number { nil }
    spec_id     { 262 }
  end
end
