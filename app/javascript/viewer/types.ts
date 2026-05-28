// Shape of the payload MeasurementViewerSerializer bakes into the report HTML
// data attribute. Mirrors app/services/measurement_viewer_serializer.rb.

export interface ViewerFacet {
  facet_id: string;
  vertices: [number, number][]; // WGS84 [lon, lat]
  pitch_ratio: number;
  pitch_degrees: number;
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
}

export interface GeoJSONPolygon {
  type: string;
  coordinates: number[][][];
}
