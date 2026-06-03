# Shared logic for the interactive report's LiDAR point-cloud overlay (ADR-013).
#
# The sidecar is internal-only, so the browser fetches points THROUGH Rails: the
# contractor (JobsController) and token-gated public (ReportsController) report
# surfaces each expose a `lidar_points` action that includes this concern and
# calls `render_lidar_points(@measurement)`. The concern proxies to the sidecar's
# /pipeline/lidar-points stage, which decodes the cached cropped array and
# reprojects it to WGS84 [lon, lat, elev_ft] (UTM never crosses the boundary).
#
# Failure posture: never 5xx the overlay. A measurement with no usable LiDAR
# returns 200 with an empty points list + a reason; a sidecar transport error
# returns 200 with an "unavailable" reason so the viewer can show a quiet note
# rather than a broken control.
module LidarPointsResponder
  extend ActiveSupport::Concern

  private

  def render_lidar_points(measurement)
    if measurement.nil? || !measurement.lidar_available?
      return render json: empty_points(reason: "lidar_unavailable")
    end

    point_array_ref = measurement.lidar["point_array_ref"]
    building_polygon = measurement.footprint
    if point_array_ref.blank? || building_polygon.blank?
      return render json: empty_points(reason: "lidar_unavailable")
    end

    response_body = SidecarClient.new.lidar_points(
      point_array_ref: point_array_ref,
      building_polygon: building_polygon
    )
    render json: response_body
  rescue SidecarClient::Error => e
    # The points are a non-essential enhancement; a transport/decode failure or a
    # cache miss must not break the report. Log it and tell the viewer to show a
    # quiet "points unavailable" note.
    Rails.logger.warn("[lidar_points] #{e.class}: #{e.message}")
    render json: empty_points(reason: "lidar_unavailable")
  end

  def empty_points(reason:)
    { points: [], point_count: 0, returned_count: 0, bounds: nil, reason: reason }
  end
end
