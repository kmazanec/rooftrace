# Solid Cable schema — the `cable` DB pool (CABLE_DATABASE_URL). Mirrors the
# table shipped by solid_cable's install generator (db/cable_schema.rb), expressed
# as a migration so `db:prepare` builds it per-pool (schema_format is :sql, so the
# secondary pools are migration-built, not schema-loaded). See config/cable.yml.
class CreateSolidCableMessages < ActiveRecord::Migration[8.0]
  def change
    create_table "solid_cable_messages", force: :cascade do |t|
      t.binary "channel", limit: 1024, null: false
      t.binary "payload", limit: 536870912, null: false
      t.datetime "created_at", null: false
      t.integer "channel_hash", limit: 8, null: false
      t.index [ "channel" ], name: "index_solid_cable_messages_on_channel"
      t.index [ "channel_hash" ], name: "index_solid_cable_messages_on_channel_hash"
      t.index [ "created_at" ], name: "index_solid_cable_messages_on_created_at"
    end
  end
end
