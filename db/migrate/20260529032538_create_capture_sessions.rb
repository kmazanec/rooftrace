class CreateCaptureSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :capture_sessions, id: :uuid do |t|
      t.uuid :job_id, null: false
      t.string :session_id, null: false
      t.string :manifest_version, null: false
      t.datetime :started_at
      t.datetime :ended_at
      t.jsonb :gps_seed
      t.jsonb :device_info
      t.string :world_mesh_ref
      t.integer :world_mesh_vertex_count
      t.jsonb :raw_manifest

      t.timestamps
    end

    add_index :capture_sessions, :job_id
    add_index :capture_sessions, :session_id, unique: true
    add_foreign_key :capture_sessions, :jobs
  end
end
