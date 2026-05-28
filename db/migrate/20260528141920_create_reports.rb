class CreateReports < ActiveRecord::Migration[8.1]
  def change
    create_table :reports, id: :uuid do |t|
      t.references :job, type: :uuid, foreign_key: true, null: true

      # Opaque public-share token (ADR-016): 32-char base32, unique-indexed.
      # Knowing it grants read-only access to the report at /r/:token.
      t.string :share_token, null: false

      t.timestamps
    end
    add_index :reports, :share_token, unique: true
  end
end
