class CreateJobs < ActiveRecord::Migration[8.1]
  def change
    create_table :jobs, id: :uuid do |t|
      # The address the contractor submitted. Full job fields land later; for
      # now the record only needs to exist so it can carry an iOS capture token.
      t.string :address, null: false, default: ""

      # Job-scoped bearer for iOS capture uploads (ADR-016): 32-char base32,
      # 24h TTL. Unique so a token resolves to exactly one job.
      t.string :capture_token, null: false
      t.datetime :capture_token_expires_at, null: false

      t.timestamps
    end
    add_index :jobs, :capture_token, unique: true
  end
end
