// Shape of the payload MeasurementViewerSerializer bakes into the report HTML
// data attribute. Mirrors app/services/measurement_viewer_serializer.rb.

// A facet boundary vertex: WGS84 [lon, lat], optionally with an elevation
// (metres) when the facet came from the LiDAR plane fit. The elevation is what
// lets the viewer render the facet as a true tilted plane (real pitch).
export type Vertex = [number, number] | [number, number, number];

export interface ViewerFacet {
  facet_id: string;
  vertices: Vertex[];
  pitch_ratio: number | null;
  pitch_degrees: number | null;
  area_sq_ft: number;
  source: string;
  confidence: number;
}

export interface ViewerFeature {
  label: string;
  bbox_norm: [number, number, number, number]; // image-space [x0,y0,x1,y1]
  verified: boolean;
  source: string;
  confidence: number;
}

// One projected on-site overlay: the result of projecting the measured roof onto
// a capture photo. The viewer renders these as an On-Site Visualization gallery
// and cross-highlights facets against it. URLs may be null (a missing/unsigned
// artifact ref); the gallery skips those entries.
export interface OnSiteVisualization {
  composite_url: string | null;
  overlay_svg_url: string | null;
  pose_confidence: number | null;
  low_pose_confidence: boolean;
  caption: string | null;
}

export interface ViewerPayload {
  address: string | null;
  generated_at: string | null;
  source: string | null;
  confidence: number | null;
  total_area_sq_ft: number | null;
  total_perimeter_ft: number | null;
  primary_pitch_ratio: number | null;
  primary_pitch_degrees: number | null;
  bounds: [number, number, number, number] | null; // [minLon,minLat,maxLon,maxLat]
  facets: ViewerFacet[];
  features: ViewerFeature[];
  roof_outline: GeoJSONPolygon | null;
  footprint: GeoJSONPolygon | null;
  warnings: string[];
  attributions: string[];
  on_site_visualizations: OnSiteVisualization[];
}

export interface GeoJSONPolygon {
  type: string;
  coordinates: number[][][];
}

// Response of the LiDAR-points overlay endpoint (Rails proxies the sidecar's
// /pipeline/lidar-points). `points` are [lon, lat, elevation_ft] in WGS84.
// `reason` is set when there are no points (e.g. "lidar_unavailable").
export interface LidarPointsResponse {
  points: [number, number, number][];
  point_count: number;
  returned_count: number;
  bounds: [number, number, number, number] | null;
  reason?: string;
}
