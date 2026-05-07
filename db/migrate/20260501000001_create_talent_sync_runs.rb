class CreateTalentSyncRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :talent_sync_runs do |t|
      t.string  :region,        null: false
      t.string  :locale,        null: false
      t.boolean :force,         null: false, default: false
      t.string  :status,        null: false, default: "running" # running | success | failure | aborted_regression
      t.text    :error_message
      t.jsonb   :failed_specs,  null: false, default: []        # array of spec_id ints
      t.jsonb   :counts,        null: false, default: {}        # { class:, spec:, hero:, pvp:, edges:, ... }
      t.jsonb   :tsa_counts,    null: false, default: {}        # { class:, spec:, hero: } at completion
      t.jsonb   :regression,    null: false, default: {}        # { detected: bool, details: [...] }
      t.datetime :started_at,   null: false
      t.datetime :completed_at

      t.timestamps
    end

    add_index :talent_sync_runs, :started_at
    add_index :talent_sync_runs, %i[status started_at]
  end
end
