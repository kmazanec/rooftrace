class CreateCaptures < ActiveRecord::Migration[8.1]
  def change
    create_table :captures, id: :uuid do |t|
      t.uuid :capture_session_id, null: false
      t.integer :sequence_index, null: false
      t.string :prompt_label
      t.datetime :captured_at
      t.string :photo_ref
      t.string :depth_ref
      t.jsonb :gps
      t.jsonb :attitude
      t.jsonb :camera_intrinsics
      t.jsonb :camera_extrinsics

      t.timestamps
    end

    add_index :captures, :capture_session_id
    add_foreign_key :captures, :capture_sessions
  end
end
