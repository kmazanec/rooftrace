require "rails_helper"
require "webmock/rspec"

# SidecarClient per-stage method tests.
#
# Two layers per the spec:
#   - Schema-guard unit tests (WebMock-stubbed HTTP, fast)
#   - At least one real round-trip against the booted sidecar subprocess
#
# WebMock disables all non-localhost connections; localhost is re-allowed in
# spec/support/webmock.rb so the real-sidecar tests keep working.
RSpec.describe SidecarClient, type: :service do
  # ---------------------------------------------------------------------------
  # Shared helpers
  # ---------------------------------------------------------------------------

  let(:secret) { "test-shared-secret" }
  let(:base)   { "http://127.0.0.1:19999" }
  let(:client) { described_class.new(base_url: base, shared_secret: secret) }

  # Reusable fixture polygons
  let(:building_polygon) do
    {
      "type" => "Polygon",
      "coordinates" => [
        [
          [ -96.7026, 40.8136 ],
          [ -96.7022, 40.8136 ],
          [ -96.7022, 40.8139 ],
          [ -96.7026, 40.8139 ],
          [ -96.7026, 40.8136 ]
        ]
      ],
      "source" => "imagery",
      "confidence" => 0.9
    }
  end

  let(:refined_polygon) do
    {
      "type" => "Polygon",
      "coordinates" => [
        [
          [ -96.70258, 40.81362 ],
          [ -96.70222, 40.81361 ],
          [ -96.70223, 40.81388 ],
          [ -96.70259, 40.81389 ],
          [ -96.70258, 40.81362 ]
        ]
      ],
      "source" => "imagery",
      "confidence" => 0.9
    }
  end

  # Helper: stub a sidecar POST; returns parsed JSON of `response_body`.
  def stub_sidecar(path, response_body, status: 200)
    stub_request(:post, "#{base}#{path}")
      .to_return(
        status: status,
        body: response_body.is_a?(String) ? response_body : response_body.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  def bearer_header
    { "Authorization" => "Bearer #{secret}" }
  end

  def valid_measurement_geometry
    {
      "pipelineSchemaVersion" => PipelineSchema.version,
      "facets" => [
        {
          "facet_id" => "F1",
          "vertices" => [ [ -96.70258, 40.81362 ], [ -96.7024, 40.81361 ], [ -96.70241, 40.81375 ] ],
          "pitch_ratio" => 6.0,
          "pitch_degrees" => 26.57,
          "area_sq_ft" => 712.4,
          "source" => "lidar",
          "confidence" => 0.93
        }
      ],
      "total_area_sq_ft" => 712.4,
      "primary_pitch_ratio" => 6.0,
      "primary_pitch_degrees" => 26.57,
      "source" => "lidar",
      "confidence" => 0.92,
      "warnings" => []
    }
  end

  # ---------------------------------------------------------------------------
  # SchemaError class
  # ---------------------------------------------------------------------------

  describe "SidecarClient::SchemaError" do
    it "is a subclass of SidecarClient::Error" do
      expect(described_class::SchemaError.ancestors).to include(described_class::Error)
    end
  end

  # ---------------------------------------------------------------------------
  # resolve_address
  # ---------------------------------------------------------------------------

  describe "#resolve_address / .resolve_address" do
    let(:path) { "/pipeline/resolve-address" }

    let(:valid_response) do
      {
        "pipelineSchemaVersion" => PipelineSchema.version,
        "geocode" => {
          "raw" => "1600 Pennsylvania Ave NW, Washington, DC 20500",
          "normalized" => "1600 Pennsylvania Avenue NW, Washington, DC 20500, USA",
          "lon" => -77.0365,
          "lat" => 38.8977,
          "source" => "imagery",
          "confidence" => 0.92
        },
        "parcel_polygon" => nil,
        "building_polygons" => [
          {
            "type" => "Polygon",
            "coordinates" => [
              [
                [ -77.0367, 38.8975 ],
                [ -77.0363, 38.8975 ],
                [ -77.0363, 38.8979 ],
                [ -77.0367, 38.8979 ],
                [ -77.0367, 38.8975 ]
              ]
            ],
            "source" => "imagery",
            "confidence" => 0.88
          }
        ],
        "attribution" => [ { "name" => "Nominatim / OpenStreetMap" } ]
      }
    end

    context "valid input and valid response (webmock)" do
      before { stub_sidecar(path, valid_response) }

      it "POSTs to /pipeline/resolve-address with bearer header" do
        client.resolve_address(address: "1600 Pennsylvania Ave NW, Washington, DC 20500")
        expect(
          a_request(:post, "#{base}#{path}").with(headers: bearer_header)
        ).to have_been_made.once
      end

      it "injects pipelineSchemaVersion into the request body" do
        client.resolve_address(address: "1600 Pennsylvania Ave NW, Washington, DC 20500")
        expect(
          a_request(:post, "#{base}#{path}").with { |req|
            JSON.parse(req.body)["pipelineSchemaVersion"] == PipelineSchema.version
          }
        ).to have_been_made
      end

      it "request body validates as ResolveAddressRequest" do
        client.resolve_address(address: "1600 Pennsylvania Ave NW, Washington, DC 20500")
        sent_body = JSON.parse(WebMock::RequestRegistry.instance.requested_signatures.hash.keys.first.body)
        expect(PipelineSchema.errors_for("ResolveAddressRequest", sent_body)).to be_empty
      end

      it "returns the parsed response hash" do
        result = client.resolve_address(address: "1600 Pennsylvania Ave NW, Washington, DC 20500")
        expect(result["building_polygons"]).to be_an(Array)
        expect(result["geocode"]["lat"]).to eq(38.8977)
      end
    end

    context "invalid request — blank address" do
      it "raises SchemaError naming the request entity before sending" do
        expect {
          client.resolve_address(address: "")
        }.to raise_error(described_class::SchemaError, /ResolveAddressRequest/)
        expect(a_request(:post, "#{base}#{path}")).not_to have_been_made
      end
    end

    context "response violates contract" do
      let(:bad_response) do
        # Missing required 'building_polygons' field
        {
          "pipelineSchemaVersion" => PipelineSchema.version,
          "geocode" => { "raw" => "1600 Pennsylvania Ave" },
          "attribution" => [ { "name" => "test" } ]
        }
      end

      before { stub_sidecar(path, bad_response) }

      it "raises SchemaError naming the response entity" do
        expect {
          client.resolve_address(address: "1600 Pennsylvania Ave NW, Washington, DC 20500")
        }.to raise_error(described_class::SchemaError, /ResolveAddressResponse/)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # render_imagery
  # ---------------------------------------------------------------------------

  describe "#render_imagery / .render_imagery" do
    let(:path) { "/pipeline/render-imagery" }

    let(:valid_response) do
      {
        "pipelineSchemaVersion" => PipelineSchema.version,
        "image_tile_ref" => "cache/tiles/9f2c1ab3.png",
        "image_geo_bounds" => [ -96.7028, 40.8134, -96.702, 40.8141 ],
        "attribution" => [ { "name" => "Mapbox" } ],
        "warnings" => []
      }
    end

    context "valid input and valid response (webmock)" do
      before { stub_sidecar(path, valid_response) }

      it "POSTs to /pipeline/render-imagery with bearer header" do
        client.render_imagery(building_polygon: building_polygon, size_px: 1024)
        expect(
          a_request(:post, "#{base}#{path}").with(headers: bearer_header)
        ).to have_been_made.once
      end

      it "injects pipelineSchemaVersion and required fields in request body" do
        client.render_imagery(building_polygon: building_polygon, size_px: 1024)
        expect(
          a_request(:post, "#{base}#{path}").with { |req|
            body = JSON.parse(req.body)
            body["pipelineSchemaVersion"] == PipelineSchema.version &&
              body["size_px"] == 1024 &&
              body["building_polygon"].is_a?(Hash)
          }
        ).to have_been_made
      end

      it "omits target_gsd_m when nil" do
        client.render_imagery(building_polygon: building_polygon, size_px: 512)
        expect(
          a_request(:post, "#{base}#{path}").with { |req|
            !JSON.parse(req.body).key?("target_gsd_m")
          }
        ).to have_been_made
      end

      it "includes target_gsd_m when provided" do
        client.render_imagery(building_polygon: building_polygon, size_px: 512, target_gsd_m: 0.6)
        expect(
          a_request(:post, "#{base}#{path}").with { |req|
            JSON.parse(req.body)["target_gsd_m"] == 0.6
          }
        ).to have_been_made
      end

      it "returns the parsed response hash" do
        result = client.render_imagery(building_polygon: building_polygon, size_px: 1024)
        expect(result["image_tile_ref"]).to eq("cache/tiles/9f2c1ab3.png")
        expect(result["image_geo_bounds"]).to be_an(Array)
      end
    end

    context "invalid request — missing size_px (size_px: 0)" do
      it "raises SchemaError naming the request entity before sending" do
        expect {
          client.render_imagery(building_polygon: building_polygon, size_px: 0)
        }.to raise_error(described_class::SchemaError, /RenderImageryRequest/)
        expect(a_request(:post, "#{base}#{path}")).not_to have_been_made
      end
    end

    context "response violates contract" do
      let(:bad_response) do
        # Missing required 'image_tile_ref'
        {
          "pipelineSchemaVersion" => PipelineSchema.version,
          "image_geo_bounds" => [ -96.7028, 40.8134, -96.702, 40.8141 ]
        }
      end

      before { stub_sidecar(path, bad_response) }

      it "raises SchemaError naming the response entity" do
        expect {
          client.render_imagery(building_polygon: building_polygon, size_px: 1024)
        }.to raise_error(described_class::SchemaError, /RenderImageryResponse/)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # render_images (report map PNG — DISTINCT from render_imagery)
  # ---------------------------------------------------------------------------

  describe "#render_images / .render_images" do
    let(:path) { "/pipeline/render-images" }
    let(:job_id) { "11111111-1111-4111-8111-111111111111" }
    let(:bbox) { [ -96.7028, 40.8134, -96.702, 40.8141 ] }

    let(:valid_response) do
      {
        "pipelineSchemaVersion" => PipelineSchema.version,
        "job_id" => job_id,
        "image_ref" => "artifacts/#{job_id}/images/map-9f2c1ab3.png"
      }
    end

    context "valid input and valid response (webmock)" do
      before { stub_sidecar(path, valid_response) }

      it "POSTs to /pipeline/render-images with bearer header and required fields" do
        client.render_images(job_id: job_id, bbox: bbox, width_px: 1024, height_px: 768)
        expect(
          a_request(:post, "#{base}#{path}").with(headers: bearer_header) { |req|
            body = JSON.parse(req.body)
            body["pipelineSchemaVersion"] == PipelineSchema.version &&
              body["job_id"] == job_id &&
              body["bbox"] == bbox &&
              body["width_px"] == 1024 &&
              body["height_px"] == 768
          }
        ).to have_been_made.once
      end

      it "returns the parsed response hash with image_ref" do
        result = client.render_images(job_id: job_id, bbox: bbox, width_px: 1024, height_px: 768)
        expect(result["image_ref"]).to eq("artifacts/#{job_id}/images/map-9f2c1ab3.png")
      end
    end

    context "invalid request — width_px below 1" do
      it "raises SchemaError naming the request entity before sending" do
        expect {
          client.render_images(job_id: job_id, bbox: bbox, width_px: 0, height_px: 768)
        }.to raise_error(described_class::SchemaError, /RenderImageRequest/)
        expect(a_request(:post, "#{base}#{path}")).not_to have_been_made
      end
    end

    context "response violates contract" do
      let(:bad_response) do
        { "pipelineSchemaVersion" => PipelineSchema.version, "job_id" => job_id } # missing image_ref
      end

      before { stub_sidecar(path, bad_response) }

      it "raises SchemaError naming the response entity" do
        expect {
          client.render_images(job_id: job_id, bbox: bbox, width_px: 1024, height_px: 768)
        }.to raise_error(described_class::SchemaError, /RenderImageResponse/)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # ingest_lidar
  # ---------------------------------------------------------------------------

  describe "#ingest_lidar / .ingest_lidar" do
    let(:path) { "/pipeline/ingest-lidar" }

    let(:valid_response) do
      {
        "pipelineSchemaVersion" => PipelineSchema.version,
        "lidar" => {
          "status" => "LIDAR_AVAILABLE",
          "point_array_ref" => "cache/lidar/9f2c1ab3.npy",
          "point_count" => 5213,
          "work_unit" => {
            "name" => "NE_Lancaster_2020",
            "year" => 2020,
            "quality_level" => "QL2",
            "epsg" => 32614
          },
          "source" => "lidar",
          "confidence" => 0.95
        },
        "utm_zone" => 32614,
        "bounds_utm" => [ 694512.3, 4519021.7, 694548.9, 4519055.2 ],
        "warnings" => [],
        "attribution" => [ { "name" => "USGS 3DEP" } ]
      }
    end

    context "valid input and valid response (webmock)" do
      before { stub_sidecar(path, valid_response) }

      it "POSTs to /pipeline/ingest-lidar with bearer header" do
        client.ingest_lidar(building_polygon: building_polygon)
        expect(
          a_request(:post, "#{base}#{path}").with(headers: bearer_header)
        ).to have_been_made.once
      end

      it "injects pipelineSchemaVersion and building_polygon in request body" do
        client.ingest_lidar(building_polygon: building_polygon)
        expect(
          a_request(:post, "#{base}#{path}").with { |req|
            body = JSON.parse(req.body)
            body["pipelineSchemaVersion"] == PipelineSchema.version &&
              body["building_polygon"].is_a?(Hash)
          }
        ).to have_been_made
      end

      it "omits parcel_polygon when nil" do
        client.ingest_lidar(building_polygon: building_polygon)
        expect(
          a_request(:post, "#{base}#{path}").with { |req|
            !JSON.parse(req.body).key?("parcel_polygon")
          }
        ).to have_been_made
      end

      it "includes parcel_polygon when provided" do
        client.ingest_lidar(building_polygon: building_polygon, parcel_polygon: refined_polygon)
        expect(
          a_request(:post, "#{base}#{path}").with { |req|
            JSON.parse(req.body)["parcel_polygon"].is_a?(Hash)
          }
        ).to have_been_made
      end

      it "returns the parsed response hash" do
        result = client.ingest_lidar(building_polygon: building_polygon)
        expect(result["lidar"]["status"]).to eq("LIDAR_AVAILABLE")
        expect(result["utm_zone"]).to eq(32614)
      end
    end

    context "response violates contract" do
      let(:bad_response) do
        # Missing required 'lidar' field
        {
          "pipelineSchemaVersion" => PipelineSchema.version,
          "utm_zone" => 32614
        }
      end

      before { stub_sidecar(path, bad_response) }

      it "raises SchemaError naming the response entity" do
        expect {
          client.ingest_lidar(building_polygon: building_polygon)
        }.to raise_error(described_class::SchemaError, /IngestLidarResponse/)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # lidar_points
  # ---------------------------------------------------------------------------

  describe "#lidar_points / .lidar_points" do
    let(:path) { "/pipeline/lidar-points" }

    let(:valid_response) do
      {
        "pipelineSchemaVersion" => PipelineSchema.version,
        "points" => [ [ -96.7025, 40.8137, 1082.5 ], [ -96.7024, 40.8138, 1083.1 ] ],
        "point_count" => 5213,
        "returned_count" => 2,
        "bounds" => [ -96.7025, 40.8137, -96.7024, 40.8138 ]
      }
    end

    context "valid input and valid response (webmock)" do
      before { stub_sidecar(path, valid_response) }

      it "POSTs to /pipeline/lidar-points with the bearer header" do
        client.lidar_points(point_array_ref: "cache/lidar/x.npy", building_polygon: building_polygon)
        expect(
          a_request(:post, "#{base}#{path}").with(headers: bearer_header)
        ).to have_been_made.once
      end

      it "injects pipelineSchemaVersion, point_array_ref and building_polygon" do
        client.lidar_points(point_array_ref: "cache/lidar/x.npy", building_polygon: building_polygon)
        expect(
          a_request(:post, "#{base}#{path}").with { |req|
            body = JSON.parse(req.body)
            body["pipelineSchemaVersion"] == PipelineSchema.version &&
              body["point_array_ref"] == "cache/lidar/x.npy" &&
              body["building_polygon"].is_a?(Hash)
          }
        ).to have_been_made
      end

      it "omits max_points when nil and includes it when provided" do
        client.lidar_points(point_array_ref: "cache/lidar/x.npy", building_polygon: building_polygon)
        expect(
          a_request(:post, "#{base}#{path}").with { |req| !JSON.parse(req.body).key?("max_points") }
        ).to have_been_made

        client.lidar_points(point_array_ref: "cache/lidar/x.npy", building_polygon: building_polygon, max_points: 5000)
        expect(
          a_request(:post, "#{base}#{path}").with { |req| JSON.parse(req.body)["max_points"] == 5000 }
        ).to have_been_made
      end

      it "returns the parsed response hash" do
        result = client.lidar_points(point_array_ref: "cache/lidar/x.npy", building_polygon: building_polygon)
        expect(result["returned_count"]).to eq(2)
        expect(result["points"].length).to eq(2)
      end
    end

    context "response violates contract" do
      let(:bad_response) do
        # Missing required 'points'/'point_count'/'returned_count'.
        { "pipelineSchemaVersion" => PipelineSchema.version }
      end

      before { stub_sidecar(path, bad_response) }

      it "raises SchemaError naming the response entity" do
        expect {
          client.lidar_points(point_array_ref: "cache/lidar/x.npy", building_polygon: building_polygon)
        }.to raise_error(described_class::SchemaError, /LidarPointsResponse/)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # refine_outline
  # ---------------------------------------------------------------------------

  describe "#refine_outline / .refine_outline" do
    let(:path) { "/pipeline/refine-outline" }

    let(:valid_response) do
      {
        "pipelineSchemaVersion" => PipelineSchema.version,
        "refined_polygon" => {
          "type" => "Polygon",
          "coordinates" => [
            [
              [ -96.70258, 40.81362 ],
              [ -96.70222, 40.81361 ],
              [ -96.70223, 40.81388 ],
              [ -96.70259, 40.81389 ],
              [ -96.70258, 40.81362 ]
            ]
          ],
          "source" => "imagery",
          "confidence" => 0.9
        },
        "iou_with_prior" => 0.91,
        "sam2_backend" => "local",
        "warnings" => []
      }
    end

    let(:image_geo_bounds) { [ -96.7028, 40.8134, -96.702, 40.8141 ] }

    context "valid input and valid response (webmock)" do
      before { stub_sidecar(path, valid_response) }

      it "POSTs to /pipeline/refine-outline with bearer header" do
        client.refine_outline(
          image_tile_ref: "cache/tiles/abc.png",
          prior_polygon: building_polygon,
          image_geo_bounds: image_geo_bounds
        )
        expect(
          a_request(:post, "#{base}#{path}").with(headers: bearer_header)
        ).to have_been_made.once
      end

      it "request body contains required fields with pipelineSchemaVersion" do
        client.refine_outline(
          image_tile_ref: "cache/tiles/abc.png",
          prior_polygon: building_polygon,
          image_geo_bounds: image_geo_bounds
        )
        expect(
          a_request(:post, "#{base}#{path}").with { |req|
            body = JSON.parse(req.body)
            body["pipelineSchemaVersion"] == PipelineSchema.version &&
              body["image_tile_ref"] == "cache/tiles/abc.png" &&
              body["prior_polygon"].is_a?(Hash) &&
              body["image_geo_bounds"].is_a?(Array)
          }
        ).to have_been_made
      end

      it "returns the parsed response hash" do
        result = client.refine_outline(
          image_tile_ref: "cache/tiles/abc.png",
          prior_polygon: building_polygon,
          image_geo_bounds: image_geo_bounds
        )
        expect(result["refined_polygon"]).to be_a(Hash)
        expect(result["iou_with_prior"]).to be_a(Numeric)
        expect(result["sam2_backend"]).to eq("local")
      end
    end

    context "invalid request — image_geo_bounds wrong length" do
      # image_geo_bounds must be exactly 4 items (minItems: 4, maxItems: 4)
      it "raises SchemaError naming the request entity before sending" do
        expect {
          client.refine_outline(
            image_tile_ref: "cache/tiles/abc.png",
            prior_polygon: building_polygon,
            image_geo_bounds: [ -96.7028, 40.8134 ]  # only 2 items, needs 4
          )
        }.to raise_error(described_class::SchemaError, /RefineOutlineRequest/)
        expect(a_request(:post, "#{base}#{path}")).not_to have_been_made
      end
    end

    context "response violates contract — bad sam2_backend" do
      let(:bad_response) do
        {
          "pipelineSchemaVersion" => PipelineSchema.version,
          "refined_polygon" => refined_polygon,
          "iou_with_prior" => 0.91,
          "sam2_backend" => "unknown_backend"
        }
      end

      before { stub_sidecar(path, bad_response) }

      it "raises SchemaError naming the response entity" do
        expect {
          client.refine_outline(
            image_tile_ref: "cache/tiles/abc.png",
            prior_polygon: building_polygon,
            image_geo_bounds: image_geo_bounds
          )
        }.to raise_error(described_class::SchemaError, /RefineOutlineResponse/)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # fit_planes
  # ---------------------------------------------------------------------------

  describe "#fit_planes / .fit_planes" do
    let(:path) { "/pipeline/fit-planes" }

    context "valid input and valid response (webmock)" do
      before { stub_sidecar(path, valid_measurement_geometry) }

      it "POSTs to /pipeline/fit-planes with bearer header" do
        client.fit_planes(
          point_array_ref: "cache/lidar/9f2c1ab3.npy",
          utm_zone: 32614,
          refined_polygon: refined_polygon
        )
        expect(
          a_request(:post, "#{base}#{path}").with(headers: bearer_header)
        ).to have_been_made.once
      end

      it "request body contains all required FitPlanesRequest fields" do
        client.fit_planes(
          point_array_ref: "cache/lidar/9f2c1ab3.npy",
          utm_zone: 32614,
          refined_polygon: refined_polygon
        )
        expect(
          a_request(:post, "#{base}#{path}").with { |req|
            body = JSON.parse(req.body)
            body["pipelineSchemaVersion"] == PipelineSchema.version &&
              body["point_array_ref"] == "cache/lidar/9f2c1ab3.npy" &&
              body["utm_zone"] == 32614 &&
              body["refined_polygon"].is_a?(Hash)
          }
        ).to have_been_made
      end

      it "returns the parsed MeasurementGeometry hash" do
        result = client.fit_planes(
          point_array_ref: "cache/lidar/9f2c1ab3.npy",
          utm_zone: 32614,
          refined_polygon: refined_polygon
        )
        expect(result["facets"]).to be_an(Array)
        expect(result["total_area_sq_ft"]).to be_a(Numeric)
      end
    end

    context "response violates contract" do
      let(:bad_response) do
        # Missing required 'facets', 'total_area_sq_ft', etc.
        {
          "pipelineSchemaVersion" => PipelineSchema.version,
          "source" => "lidar",
          "confidence" => 0.9
        }
      end

      before { stub_sidecar(path, bad_response) }

      it "raises SchemaError naming the response entity (MeasurementGeometry)" do
        expect {
          client.fit_planes(
            point_array_ref: "cache/lidar/9f2c1ab3.npy",
            utm_zone: 32614,
            refined_polygon: refined_polygon
          )
        }.to raise_error(described_class::SchemaError, /MeasurementGeometry/)
      end
    end

    context "with per-call timeout override" do
      it "uses the supplied timeout" do
        stub_sidecar(path, valid_measurement_geometry)
        expect_any_instance_of(Net::HTTP).to receive(:open_timeout=).with(30)
        expect_any_instance_of(Net::HTTP).to receive(:read_timeout=).with(30)
        client.fit_planes(
          point_array_ref: "cache/lidar/9f2c1ab3.npy",
          utm_zone: 32614,
          refined_polygon: refined_polygon,
          timeout: 30
        )
      end
    end
  end

  # ---------------------------------------------------------------------------
  # fallback_measurement
  # ---------------------------------------------------------------------------

  describe "#fallback_measurement / .fallback_measurement" do
    let(:path) { "/pipeline/fallback-measurement" }

    let(:imagery_geometry) do
      valid_measurement_geometry.merge("source" => "imagery", "confidence" => 0.6)
    end

    context "valid input and valid response (webmock)" do
      before { stub_sidecar(path, imagery_geometry) }

      it "POSTs to /pipeline/fallback-measurement with bearer header" do
        client.fallback_measurement(
          refined_polygon: refined_polygon,
          inferred_pitch_degrees: 30.0,
          utm_zone: 32614
        )
        expect(
          a_request(:post, "#{base}#{path}").with(headers: bearer_header)
        ).to have_been_made.once
      end

      it "request body contains all required FallbackMeasurementRequest fields" do
        client.fallback_measurement(
          refined_polygon: refined_polygon,
          inferred_pitch_degrees: 30.0,
          utm_zone: 32614
        )
        expect(
          a_request(:post, "#{base}#{path}").with { |req|
            body = JSON.parse(req.body)
            body["pipelineSchemaVersion"] == PipelineSchema.version &&
              body["inferred_pitch_degrees"] == 30.0 &&
              body["utm_zone"] == 32614 &&
              body["refined_polygon"].is_a?(Hash)
          }
        ).to have_been_made
      end

      it "returns the parsed MeasurementGeometry hash" do
        result = client.fallback_measurement(
          refined_polygon: refined_polygon,
          inferred_pitch_degrees: 30.0,
          utm_zone: 32614
        )
        expect(result["facets"]).to be_an(Array)
        expect(result["total_area_sq_ft"]).to be_a(Numeric)
      end
    end

    context "invalid request — pitch out of range" do
      it "raises SchemaError naming the request entity before sending" do
        expect {
          client.fallback_measurement(
            refined_polygon: refined_polygon,
            inferred_pitch_degrees: 95.0,  # >90 is invalid per schema
            utm_zone: 32614
          )
        }.to raise_error(described_class::SchemaError, /FallbackMeasurementRequest/)
        expect(a_request(:post, "#{base}#{path}")).not_to have_been_made
      end
    end

    context "response violates contract" do
      let(:bad_response) do
        # Negative total_area_sq_ft violates the schema's `minimum: 0.0`. (Pitch is
        # nullable on the imagery path, so an absent pitch is NOT a contract break.)
        {
          "pipelineSchemaVersion" => PipelineSchema.version,
          "facets" => [],
          "total_area_sq_ft" => -500.0,
          "source" => "imagery",
          "confidence" => 0.6
        }
      end

      before { stub_sidecar(path, bad_response) }

      it "raises SchemaError naming the response entity (MeasurementGeometry)" do
        expect {
          client.fallback_measurement(
            refined_polygon: refined_polygon,
            inferred_pitch_degrees: 30.0,
            utm_zone: 32614
          )
        }.to raise_error(described_class::SchemaError, /MeasurementGeometry/)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Timeout override — per-call :timeout kwarg
  # ---------------------------------------------------------------------------

  describe "per-call timeout override" do
    it "defaults to DEFAULT_TIMEOUT_SECONDS when not supplied" do
      stub_sidecar("/pipeline/fallback-measurement", valid_measurement_geometry)
      expect_any_instance_of(Net::HTTP).to receive(:open_timeout=).with(described_class::DEFAULT_TIMEOUT_SECONDS)
      expect_any_instance_of(Net::HTTP).to receive(:read_timeout=).with(described_class::DEFAULT_TIMEOUT_SECONDS)
      client.fallback_measurement(
        refined_polygon: refined_polygon,
        inferred_pitch_degrees: 20.0,
        utm_zone: 32614
      )
    end

    it "uses the supplied timeout when provided" do
      stub_sidecar("/pipeline/resolve-address",
                   {
                     "pipelineSchemaVersion" => PipelineSchema.version,
                     "geocode" => { "raw" => "test addr" },
                     "building_polygons" => [
                       {
                         "type" => "Polygon",
                         "coordinates" => [
                           [
                             [ -77.0, 38.0 ], [ -77.1, 38.0 ], [ -77.1, 38.1 ], [ -77.0, 38.1 ], [ -77.0, 38.0 ]
                           ]
                         ],
                         "source" => "imagery",
                         "confidence" => 0.8
                       }
                     ],
                     "attribution" => [ { "name" => "test" } ]
                   })
      expect_any_instance_of(Net::HTTP).to receive(:open_timeout=).with(60)
      expect_any_instance_of(Net::HTTP).to receive(:read_timeout=).with(60)
      client.resolve_address(address: "test addr", timeout: 60)
    end
  end

  # ---------------------------------------------------------------------------
  # Error message format for SchemaError
  # ---------------------------------------------------------------------------

  describe "SchemaError message format" do
    it "names the entity and includes validation error details on bad request" do
      expect {
        client.resolve_address(address: "")
      }.to raise_error(described_class::SchemaError) { |e|
        expect(e.message).to include("ResolveAddressRequest")
        expect(e.message).to match(/invalid|validation|minLength/i)
      }
    end

    it "names the entity on bad response" do
      stub_sidecar("/pipeline/resolve-address", {
        "pipelineSchemaVersion" => PipelineSchema.version,
        "geocode" => { "raw" => "1600 Pennsylvania Ave" },
        "attribution" => [ { "name" => "test" } ]
      })
      expect {
        client.resolve_address(address: "1600 Pennsylvania Ave NW, Washington, DC 20500")
      }.to raise_error(described_class::SchemaError) { |e|
        expect(e.message).to include("ResolveAddressResponse")
      }
    end
  end

  # ---------------------------------------------------------------------------
  # Real round-trip: fallback_measurement against the live sidecar subprocess
  # ---------------------------------------------------------------------------

  describe "real round-trip: fallback_measurement", :real_sidecar do
    before do
      skip "real sidecar not booted (SKIP_REAL_SIDECAR=1)" if ENV["SKIP_REAL_SIDECAR"] == "1"
    end

    let(:real_client) do
      described_class.new(
        base_url: ENV.fetch("SIDECAR_URL", "http://127.0.0.1:8000"),
        shared_secret: ENV.fetch("SIDECAR_SHARED_SECRET", "test-shared-secret")
      )
    end

    it "round-trips a FallbackMeasurementRequest and validates MeasurementGeometry green" do
      result = real_client.fallback_measurement(
        refined_polygon: {
          "type" => "Polygon",
          "coordinates" => [
            [
              [ -96.70258, 40.81362 ],
              [ -96.70222, 40.81361 ],
              [ -96.70223, 40.81388 ],
              [ -96.70259, 40.81389 ],
              [ -96.70258, 40.81362 ]
            ]
          ],
          "source" => "imagery",
          "confidence" => 0.7
        },
        inferred_pitch_degrees: 30.0,
        utm_zone: 32614
      )

      expect(result["facets"]).to be_an(Array)
      expect(result["facets"]).not_to be_empty
      expect(result["total_area_sq_ft"]).to be > 0
      # Imagery fallback does NOT measure pitch: it reports null, with the
      # area-estimate disclosure warning instead of a fabricated ratio.
      expect(result["primary_pitch_ratio"]).to be_nil
      expect(result["warnings"]).to include("area_estimated_no_pitch")
      expect(result["source"]).to eq("imagery")

      errors = PipelineSchema.errors_for("MeasurementGeometry", result)
      expect(errors).to be_empty, "MeasurementGeometry schema errors: #{errors.join('; ')}"
    end

    it "raises SidecarClient::AuthError on a wrong bearer token" do
      bad_client = described_class.new(
        base_url: ENV.fetch("SIDECAR_URL", "http://127.0.0.1:8000"),
        shared_secret: "definitely-wrong-secret"
      )
      expect {
        bad_client.fallback_measurement(
          refined_polygon: {
            "type" => "Polygon",
            "coordinates" => [
              [
                [ -96.70258, 40.81362 ],
                [ -96.70222, 40.81361 ],
                [ -96.70223, 40.81388 ],
                [ -96.70259, 40.81389 ],
                [ -96.70258, 40.81362 ]
              ]
            ],
            "source" => "imagery",
            "confidence" => 0.7
          },
          inferred_pitch_degrees: 30.0,
          utm_zone: 32614
        )
      }.to raise_error(described_class::AuthError)
    end
  end
end
