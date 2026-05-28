class CreateSkeletonPings < ActiveRecord::Migration[8.1]
  def change
    create_table :skeleton_pings, id: :uuid do |t|
      t.string :job_id, null: false
      t.datetime :rails_sent_at, null: false
      t.datetime :sidecar_received_at, null: false
      t.datetime :rails_received_at, null: false
      t.integer :rtt_ms, null: false
      t.jsonb :sidecar_payload, null: false, default: {}

      t.timestamps
    end
    add_index :skeleton_pings, :job_id
  end
end
