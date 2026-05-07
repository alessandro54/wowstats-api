#!/usr/bin/env ruby
# Diagnose hero_talent_trees presence in Blizzard's talent-tree API responses.
# Usage:
#   bundle exec rails runner script/diagnose_hero_tree_sync.rb
#   bundle exec rails runner script/diagnose_hero_tree_sync.rb 71  # one spec
#
# Reports per-spec whether hero_talent_trees is present, the counts of nodes
# in each tree section, and the top-level keys returned. No DB writes.

target_spec = ARGV[0]&.to_i

client = Blizzard::Client.new(region: "us", locale: "en_US")
ns     = client.static_namespace

index = client.get("/data/wow/talent-tree/index", namespace: ns)
specs = Array(index["spec_talent_trees"])

puts "Found #{specs.size} spec_talent_trees in index"
puts "-" * 80

missing_hero = []
missing_class_spec = []

specs.each do |entry|
  href = entry.dig("key", "href").to_s
  m    = href.match(%r{/talent-tree/(\d+)/playable-specialization/(\d+)})
  next unless m

  tree_id, spec_id = m[1].to_i, m[2].to_i
  next if target_spec && spec_id != target_spec

  begin
    tree = client.get("/data/wow/talent-tree/#{tree_id}/playable-specialization/#{spec_id}", namespace: ns)
  rescue => e
    puts "spec #{spec_id} (tree #{tree_id}): ERROR — #{e.class}: #{e.message}"
    next
  end

  class_n = Array(tree["class_talent_nodes"]).size
  spec_n  = Array(tree["spec_talent_nodes"]).size
  hero_t  = Array(tree["hero_talent_trees"])
  hero_n  = hero_t.sum { |h| (Array(h["hero_talent_nodes"]).presence || Array(h["nodes"])).size }
  keys    = tree.keys.sort

  flag = ""
  if hero_t.empty?
    missing_hero << spec_id
    flag = " ⚠ NO hero_talent_trees"
  end
  missing_class_spec << spec_id if class_n.zero? && spec_n.zero?

  puts "spec #{spec_id.to_s.rjust(4)} tree #{tree_id}: class=#{class_n.to_s.rjust(3)} spec=#{spec_n.to_s.rjust(3)} " \
       "hero_trees=#{hero_t.size} hero_nodes=#{hero_n.to_s.rjust(3)}#{flag}"
  puts "  keys: #{keys.inspect}" if hero_t.empty? || ENV["VERBOSE"]
end

puts "-" * 80
puts "Specs missing hero_talent_trees: #{missing_hero.size}"
puts missing_hero.inspect if missing_hero.any?
puts "Specs missing class+spec entirely: #{missing_class_spec.size}"
puts missing_class_spec.inspect if missing_class_spec.any?
