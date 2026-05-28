class AddStatusAndIdempotencyToJobs < ActiveRecord::Migration[8.1]
  def change
    add_column :jobs, :status, :string, null: false, default: "pending"
    add_column :jobs, :polygon_selection, :integer, null: false, default: 0
    add_column :jobs, :last_error, :string
    add_index :jobs, :status
  end
end
