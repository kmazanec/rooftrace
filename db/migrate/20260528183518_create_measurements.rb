class CreateMeasurements < ActiveRecord::Migration[8.1]
  def change
    create_table :measurements, id: :uuid do |t|
      t.references :job, null: false, foreign_key: true, type: :uuid, index: true
      t.jsonb :footprint
      t.jsonb :roof_outline
      t.jsonb :lidar
      t.jsonb :facets, null: false, default: []
      t.jsonb :features, null: false, default: []
      t.jsonb :provenance, null: false, default: {}
      t.decimal :total_area_sq_ft
      t.decimal :predominant_pitch_ratio
      t.string :source, null: false
      t.decimal :confidence, null: false
      t.jsonb :warnings, null: false, default: []
      t.datetime :generated_at

      t.timestamps
    end
  end
end
