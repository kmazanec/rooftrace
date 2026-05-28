class AddPerimeterGeocodeParcelAndFingerprintToMeasurements < ActiveRecord::Migration[8.1]
  def change
    add_column :measurements, :total_perimeter_ft, :decimal
    add_column :measurements, :geocode, :jsonb
    add_column :measurements, :parcel_polygon, :jsonb
    add_column :measurements, :source_fingerprint, :string
  end
end
