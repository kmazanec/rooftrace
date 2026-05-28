FactoryBot.define do
  factory :measurement do
    job
    source { "lidar" }
    confidence { 0.9 }
    facets { [] }
    features { [] }
    provenance { {} }
    warnings { [] }
    generated_at { Time.current }

    # A realistic, schema-valid measurement the viewer can render. Facets and
    # features match the frozen Facet/Feature $defs in shared/pipeline_schema.json
    # VERBATIM (a contract spec asserts this so the fixture can never drift from
    # real orchestrator output). Vertices are internal WGS84 [lon, lat].
    trait :with_geometry do
      total_area_sq_ft { 1684.0 }
      predominant_pitch_ratio { 6.0 }
      total_perimeter_ft { 168.0 }
      geocode do
        {
          "raw" => "123 Main St, Springfield, IL",
          "normalized" => "123 Main St, Springfield, IL 62701",
          "lon" => -89.6501,
          "lat" => 39.7990,
          "source" => "nominatim",
          "confidence" => 0.92
        }
      end
      roof_outline do
        {
          "type" => "Polygon",
          "coordinates" => [ [
            [ -89.65030, 39.79890 ],
            [ -89.64990, 39.79890 ],
            [ -89.64990, 39.79920 ],
            [ -89.65030, 39.79920 ],
            [ -89.65030, 39.79890 ]
          ] ]
        }
      end
      facets do
        [
          {
            "facet_id" => "F1",
            "vertices" => [
              [ -89.65030, 39.79890 ],
              [ -89.65010, 39.79890 ],
              [ -89.65010, 39.79905 ],
              [ -89.65030, 39.79905 ]
            ],
            "pitch_ratio" => 6.0,
            "pitch_degrees" => 26.57,
            "area_sq_ft" => 842.0,
            "source" => "lidar",
            "confidence" => 0.9
          },
          {
            "facet_id" => "F2",
            "vertices" => [
              [ -89.65010, 39.79890 ],
              [ -89.64990, 39.79890 ],
              [ -89.64990, 39.79905 ],
              [ -89.65010, 39.79905 ]
            ],
            "pitch_ratio" => 3.0,
            "pitch_degrees" => 14.04,
            "area_sq_ft" => 842.0,
            "source" => "imagery",
            "confidence" => 0.55
          }
        ]
      end
      features do
        [
          {
            "label" => "chimney",
            "bbox_norm" => [ 0.40, 0.30, 0.50, 0.45 ],
            "verified" => true,
            "source" => "imagery",
            "confidence" => 0.8
          },
          {
            "label" => "vent",
            "bbox_norm" => [ 0.60, 0.55, 0.64, 0.60 ],
            "verified" => false,
            "source" => "imagery",
            "confidence" => 0.42
          }
        ]
      end
      provenance do
        {
          "pipeline_schema_version" => "0.3.0",
          "detector" => "feature-detector-v1",
          "geometry_source" => "lidar",
          "generated_at" => Time.current.utc.iso8601,
          "attributions" => {
            "imagery" => { "name" => "USDA NAIP", "license" => "Public Domain" },
            "lidar" => { "name" => "USGS 3DEP", "license" => "Public Domain" },
            "resolve_address" => { "name" => "Nominatim / OpenStreetMap", "license" => "ODbL" }
          }
        }
      end
    end

    # A fully populated, schema-passing Measurement shaped exactly like
    # MeasurementOrchestrator#build_measurement_document / #persist writes in
    # production: facets (WGS84 [lon, lat] vertices, per-facet pitch + source +
    # confidence), features (bbox_norm image-space), totals, geocode (Address),
    # and a nested provenance with the attribution sources the report footer
    # needs. Reused across the report PDF service/request/system specs (and
    # available to the viewer + JSON-export surfaces).
    trait :complete do
      source { "fusion" }
      confidence { 0.84 }
      total_area_sq_ft { 2480.5 }
      predominant_pitch_ratio { 6.0 }
      total_perimeter_ft { 214.3 }

      facets do
        [
          {
            "facet_id" => "F1",
            "vertices" => [
              [ -104.9950, 39.7380 ],
              [ -104.9940, 39.7380 ],
              [ -104.9940, 39.7390 ],
              [ -104.9950, 39.7390 ]
            ],
            "pitch_ratio" => 6.0,
            "pitch_degrees" => 26.57,
            "area_sq_ft" => 1320.0,
            "source" => "lidar",
            "confidence" => 0.91
          },
          {
            "facet_id" => "F2",
            "vertices" => [
              [ -104.9940, 39.7380 ],
              [ -104.9930, 39.7382 ],
              [ -104.9935, 39.7390 ]
            ],
            "pitch_ratio" => 4.0,
            "pitch_degrees" => 18.43,
            "area_sq_ft" => 1160.5,
            "source" => "imagery",
            "confidence" => 0.55
          }
        ]
      end

      features do
        [
          {
            "label" => "chimney",
            "bbox_norm" => [ 0.41, 0.32, 0.47, 0.40 ],
            "verified" => false,
            "source" => "imagery",
            "confidence" => 0.66
          },
          {
            "label" => "vent",
            "bbox_norm" => [ 0.70, 0.50, 0.74, 0.55 ],
            "verified" => false,
            "source" => "imagery",
            "confidence" => 0.62
          }
        ]
      end

      geocode do
        {
          "raw" => "1600 Pennsylvania Ave NW, Washington, DC 20500",
          "normalized" => "1600 Pennsylvania Avenue NW, Washington, DC 20500",
          "lon" => -104.9945,
          "lat" => 39.7385,
          "source" => "nominatim",
          "confidence" => 0.93
        }
      end

      provenance do
        {
          "pipeline_schema_version" => "0.3.0",
          "detector" => "openrouter",
          "sam2_backend" => "replicate",
          "geometry_source" => "fusion",
          "attributions" => {
            "resolve_address" => [
              { "name" => "Nominatim", "license" => "ODbL", "retrieved_at" => "2026-05-28T00:00:00Z" }
            ],
            "imagery" => [
              { "name" => "Mapbox", "license" => "Mapbox TOS", "retrieved_at" => "2026-05-28T00:00:00Z" },
              { "name" => "NAIP", "license" => "Public domain", "retrieved_at" => "2026-05-28T00:00:00Z" }
            ],
            "lidar" => [
              { "name" => "USGS 3DEP", "license" => "Public domain", "retrieved_at" => "2026-05-28T00:00:00Z" }
            ]
          },
          "generated_at" => "2026-05-28T00:00:00Z"
        }
      end
    end
  end
end
