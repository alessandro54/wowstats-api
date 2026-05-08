class AddLowerCaseLookupIndexToCharacters < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # CharactersController#show looks up characters with
  # `LOWER(region) = ? AND LOWER(realm) = ? AND LOWER(name) = ?`,
  # which the existing (name, realm, region) btree cannot serve. Add a
  # functional expression index so the lookup hits an index scan.
  def up
    add_index :characters,
              "LOWER(region), LOWER(realm), LOWER(name)",
              name: :idx_characters_lower_region_realm_name,
              algorithm: :concurrently,
              if_not_exists: true
  end

  def down
    remove_index :characters,
                 name: :idx_characters_lower_region_realm_name,
                 algorithm: :concurrently,
                 if_exists: true
  end
end
