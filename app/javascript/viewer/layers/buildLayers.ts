import { PolygonLayer, ScatterplotLayer, TextLayer } from "@deck.gl/layers";
import { colorByPitch } from "../utils/colorByPitch";
import { isLowConfidence } from "../utils/confidenceLabel";
import { boundsCenter, featurePinPositions } from "../utils/geometry";
import { BRAND_CHARCOAL, CONFIDENCE_LOW } from "../utils/brandColors";
import type { ViewerPayload, ViewerFacet, ViewerFeature } from "../types";

export interface HoverHandlers {
  onFacetHover: (info: { object?: ViewerFacet; x: number; y: number }) => void;
  onFacetClick: (info: { object?: ViewerFacet }) => void;
  onFeatureHover: (info: { object?: FeaturePin; x: number; y: number }) => void;
}

export interface FeaturePin {
  position: [number, number];
  feature: ViewerFeature;
}

// Flat facet polygons (ADR-013 fixes elevation at 0 for v1; 3D extrusion is
// v1.5). Fill is colorByPitch; the low-confidence "uncertain reading" marker is
// a dashed/lighter outline. PolygonLayer has no native dash, so we encode
// low-confidence facets with a distinct lighter outline color + thinner width.
export function buildFacetLayer(payload: ViewerPayload, handlers: HoverHandlers) {
  return new PolygonLayer<ViewerFacet>({
    id: "facets",
    data: payload.facets,
    getPolygon: (f) => f.vertices,
    extruded: false,
    getElevation: 0,
    filled: true,
    stroked: true,
    getFillColor: (f) => colorByPitch(f.pitch_ratio),
    getLineColor: (f) =>
      isLowConfidence(f.confidence) ? [...CONFIDENCE_LOW, 255] : [...BRAND_CHARCOAL, 255],
    getLineWidth: (f) => (isLowConfidence(f.confidence) ? 1 : 2),
    lineWidthUnits: "pixels",
    pickable: true,
    autoHighlight: true,
    onHover: (info) =>
      handlers.onFacetHover({ object: info.object ?? undefined, x: info.x, y: info.y }),
    onClick: (info) => handlers.onFacetClick({ object: info.object ?? undefined }),
  });
}

// Feature pins. Because Features have NO geographic center (v1 limitation), all
// pins are anchored near the roof centroid with a deterministic fan-out.
export function buildFeaturePins(payload: ViewerPayload): FeaturePin[] {
  const center = boundsCenter(payload.bounds);
  const positions = featurePinPositions(payload.features, center);
  return payload.features.map((feature, i) => ({
    position: positions[i] ?? center ?? [0, 0],
    feature,
  }));
}

export function buildFeatureLayer(pins: FeaturePin[], handlers: HoverHandlers) {
  return new ScatterplotLayer<FeaturePin>({
    id: "features",
    data: pins,
    getPosition: (p) => p.position,
    getRadius: 6,
    radiusUnits: "pixels",
    getFillColor: [...BRAND_CHARCOAL, 230],
    getLineColor: [255, 255, 255, 255],
    stroked: true,
    lineWidthMinPixels: 1,
    pickable: true,
    onHover: (info) =>
      handlers.onFeatureHover({ object: info.object ?? undefined, x: info.x, y: info.y }),
  });
}

export function buildFeatureLabelLayer(pins: FeaturePin[]) {
  return new TextLayer<FeaturePin>({
    id: "feature-labels",
    data: pins,
    getPosition: (p) => p.position,
    getText: (p) => p.feature.label,
    getSize: 11,
    getColor: [...BRAND_CHARCOAL, 255],
    getPixelOffset: [0, -14],
    fontFamily: "monospace",
    pickable: false,
  });
}
