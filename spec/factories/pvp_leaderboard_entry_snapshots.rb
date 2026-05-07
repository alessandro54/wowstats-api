FactoryBot.define do
  factory :pvp_leaderboard_entry_snapshot do
    association :character
    association :pvp_leaderboard
    pvp_sync_cycle { nil }
    snapshot_at    { Time.current }
    rank           { 1 }
    rating         { 2400 }
    wins           { 50 }
    losses         { 20 }
    spec_id        { nil }
  end
end
