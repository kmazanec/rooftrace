class CreateAppTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :app_tokens, id: :uuid do |t|
      t.string :token, null: false
      t.datetime :expires_at, null: false

      t.timestamps
    end

    add_index :app_tokens, :token, unique: true
  end
end
