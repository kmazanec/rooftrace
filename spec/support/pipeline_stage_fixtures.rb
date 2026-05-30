# Schema-valid per-stage response builders for orchestrator specs.
#
# These mirror the shapes SidecarClient returns (already schema-validated on the
# wire), so the orchestrator under test composes realistic, contract-valid
# payloads. Each builder asserts its own validity against PipelineSchema at build
# time so a drifted fixture fails fast in the spec, not mysteriously downstream.
module PipelineStageFixtures
  module_function

  def schema_version
    PipelineSchema.version
  end

  def polygon(source: "imagery", confidence: 0.9)
    {
      "type" => "Polygon",
      "coordinates" => [ [
        [ -96.70258, 40.81362 ],
        [ -96.70222, 40.81361 ],
        [ -96.70223, 40.81388 ],
        [ -96.70259, 40.81389 ],
        [ -96.70258, 40.81362 ]
      ] ],
      "source" => source,
      "confidence" => confidence
    }
  end

  def attribution
    [ { "name" => "Nominatim / OpenStreetMap", "license" => "ODbL", "url" => nil,
        "retrieved_at" => "2024-06-01T00:00:00Z" } ]
  end

  def resolve_address_response(geocode_confidence: 0.95, building_count: 1)
    polys = Array.new(building_count) { polygon }
    {
      "pipelineSchemaVersion" => schema_version,
      "geocode" => {
        "raw" => "1600 Pennsylvania Ave NW",
        "normalized" => "1600 Pennsylvania Ave NW, Washington, DC 20500",
        "lon" => -96.70240,
        "lat" => 40.81375,
        "source" => "imagery",
        "confidence" => geocode_confidence
      },
      "parcel_polygon" => polygon(source: "imagery", confidence: 0.8),
      "building_polygons" => polys,
      "attribution" => attribution,
      "warnings" => []
    }
  end

  def render_imagery_response(image_tile_ref: "cache/imagery/abc123.png", warnings: [])
    {
      "pipelineSchemaVersion" => schema_version,
      "image_tile_ref" => image_tile_ref,
      "image_geo_bounds" => [ -96.7030, 40.8133, -96.7018, 40.8141 ],
      "attribution" => [ { "name" => "Mapbox" } ],
      "warnings" => warnings
    }
  end

  def ingest_lidar_response(status: "LIDAR_AVAILABLE", warnings: [])
    available = status == "LIDAR_AVAILABLE"
    {
      "pipelineSchemaVersion" => schema_version,
      "lidar" => {
        "status" => status,
        "point_array_ref" => available ? "cache/lidar/pts.npy" : nil,
        "point_count" => available ? 50_000 : nil,
        "work_unit" => available ? { "name" => "NE_Lincoln_2020", "year" => 2020, "quality_level" => "QL2", "epsg" => 32_614 } : nil,
        "source" => "lidar",
        "confidence" => available ? 0.92 : 0.0
      },
      "utm_zone" => available ? 32_614 : nil,
      "bounds_utm" => available ? [ 100.0, 200.0, 150.0, 260.0 ] : nil,
      "warnings" => warnings,
      "attribution" => [ { "name" => "USGS 3DEP" } ]
    }
  end

  def refine_outline_response(warnings: [])
    {
      "pipelineSchemaVersion" => schema_version,
      "refined_polygon" => polygon(source: "imagery", confidence: 0.88),
      "iou_with_prior" => 0.94,
      "sam2_backend" => "local",
      "warnings" => warnings
    }
  end

  def measurement_geometry(source: "fusion", confidence: 0.9, warnings: [])
    {
      "pipelineSchemaVersion" => schema_version,
      "facets" => [ {
        "facet_id" => "F1",
        "vertices" => [ [ -96.70258, 40.81362 ], [ -96.70222, 40.81361 ], [ -96.70223, 40.81388 ] ],
        "pitch_ratio" => 6.0,
        "pitch_degrees" => 26.57,
        "area_sq_ft" => 1200.0,
        "source" => source,
        "confidence" => confidence
      } ],
      "total_area_sq_ft" => 1200.0,
      "total_perimeter_ft" => 140.0,
      "primary_pitch_ratio" => 6.0,
      "primary_pitch_degrees" => 26.57,
      "source" => source,
      "confidence" => confidence,
      "warnings" => warnings
    }
  end

  def feature(label: "chimney", confidence: 0.85)
    {
      "label" => label,
      "bbox_norm" => [ 0.4, 0.4, 0.5, 0.5 ],
      "verified" => true,
      "source" => "imagery",
      "confidence" => confidence
    }
  end
end
