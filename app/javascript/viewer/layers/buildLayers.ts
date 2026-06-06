import { PolygonLayer, ScatterplotLayer, TextLayer } from "@deck.gl/layers";
import { colorByPitch } from "../utils/colorByPitch";
import { isLowConfidence } from "../utils/confidenceLabel";
import { boundsCenter, featurePinPositions } from "../utils/geometry";
import { BRAND_CHARCOAL, CONFIDENCE_LOW, SELECTED_FILL } from "../utils/brandColors";
import type { RGBA } from "../utils/brandColors";
import { feetToMeters } from "../utils/elevation";
import type { ViewerPayload, ViewerFacet, ViewerFeature, Vertex } from "../types";

export interface HoverHandlers {
  onFacetHover: (info: { object?: ViewerFacet; x: number; y: number }) => void;
  onFacetClick: (info: { object?: ViewerFacet }) => void;
  onFeatureHover: (info: { object?: FeaturePin; x: number; y: number }) => void;
}

export interface FeaturePin {
  position: [number, number];
  feature: ViewerFeature;
}

// Facet polygons. Fill is colorByPitch; the low-confidence "uncertain reading"
// marker is a dashed/lighter outline. PolygonLayer has no native dash, so we
// encode low-confidence facets with a distinct lighter outline color + thinner
// width. `highlightedFacetId` (driven by hover on the map OR the side-panel
// table, via the roof:facet-hover bridge) gets a charcoal, thicker stroke so the
// two surfaces cross-highlight. (Charcoal not orange: the brand reserves orange
// for the CTA / PDF header bar only — see report.css.)
//
// `threeD` (the viewer's 3D-view toggle) renders each facet as a TRUE tilted
// plane: the facet vertices carry their real per-vertex elevation (metres) from
// the LiDAR plane fit, so the polygon slopes the way the roof does — actual
// pitch, not a flat extruded slab. `elevationBaseline` (the lowest facet vertex,
// metres) is subtracted so the roof sits on the basemap instead of floating at
// its absolute height. Facets without a per-vertex z (imagery-only path) fall
// back to flat. Off by default — the default top-down render is unchanged.
// Alpha-composite the translucent SELECTED_FILL over a base fill, matching how
// deck.gl's autoHighlight paints its blue on top of the object color (we drive
// the highlight ourselves now, so list-hover and the click-pin tint too).
function withSelectedTint(base: RGBA): RGBA {
  const a = SELECTED_FILL[3] / 255;
  const over = (b: number, o: number) => Math.round(b * (1 - a) + o * a);
  return [
    over(base[0], SELECTED_FILL[0]),
    over(base[1], SELECTED_FILL[1]),
    over(base[2], SELECTED_FILL[2]),
    base[3],
  ];
}

export function buildFacetLayer(
  payload: ViewerPayload,
  handlers: HoverHandlers,
  highlightedFacetId: string | null,
  threeD = false,
  elevationBaseline = 0
) {
  const toTilted = (v: Vertex): [number, number, number] => [
    v[0],
    v[1],
    v[2] === undefined ? 0 : v[2] - elevationBaseline,
  ];
  // Top-down: drop any elevation so facets render flat on the basemap. Vertices
  // now carry absolute elevation (~hundreds of metres) from the LiDAR fit; passed
  // raw to the pitch-0 camera they'd float far above z=0 and project off-screen.
  const toFlat = (v: Vertex): [number, number] => [v[0], v[1]];
  return new PolygonLayer<ViewerFacet>({
    id: "facets",
    data: payload.facets,
    getPolygon: threeD ? (f) => f.vertices.map(toTilted) : (f) => f.vertices.map(toFlat),
    // No extrusion: the 3D comes from the polygon's own per-vertex elevation, so
    // each facet is a sloped surface rather than a vertical-walled prism.
    extruded: false,
    getElevation: 0,
    filled: true,
    stroked: true,
    getFillColor: (f) => {
      const base = colorByPitch(f.pitch_ratio);
      return f.facet_id === highlightedFacetId ? withSelectedTint(base) : base;
    },
    getLineColor: (f) => {
      if (f.facet_id === highlightedFacetId) return [...BRAND_CHARCOAL, 255];
      return isLowConfidence(f.confidence) ? [...CONFIDENCE_LOW, 255] : [...BRAND_CHARCOAL, 255];
    },
    getLineWidth: (f) => {
      if (f.facet_id === highlightedFacetId) return 4;
      return isLowConfidence(f.confidence) ? 1 : 2;
    },
    lineWidthUnits: "pixels",
    pickable: true,
    // We drive the blue "selected" tint ourselves via getFillColor/highlightedFacetId
    // (so list-hover and the click-pin highlight too, not just the map pointer) —
    // so deck.gl's pointer-only autoHighlight is off to avoid a double blue.
    autoHighlight: false,
    updateTriggers: {
      getFillColor: highlightedFacetId,
      getLineColor: highlightedFacetId,
      getLineWidth: highlightedFacetId,
      getPolygon: [threeD, elevationBaseline],
    },
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

// LiDAR point-cloud overlay (ADR-013): the real 3DEP returns the facets were
// fit from, fetched lazily when the viewer's overlay toggle is switched on.
// Points are [lon, lat, elev_ft] (WGS84). Colored along the brand gray->charcoal
// ramp by relative elevation, so roof structure reads even top-down. `threeD`
// (the viewer's 3D-view toggle) lifts each point to its elevation for deck.gl's
// LNGLAT z (metres), so a tilted camera shows the real 3D roof surface.
//
// `baselineMeters` is the SHARED ground datum (the lowest facet vertex, metres),
// so the points and the tilted facet planes — fit from the same cloud, same UTM
// vertical datum — line up instead of drifting apart. (Each layer normalising to
// its own min drifts: the overlay samples lower returns than the facet vertices,
// so its smaller min lifted the points above the planes.) Falls back to the
// points' own min when there are no elevated facets (e.g. an overlay with no
// LiDAR facets). Top-down (threeD off) the points stay flat.
export function buildLidarPointLayer(
  points: [number, number, number][],
  threeD = false,
  baselineMeters: number | null = null
) {
  const elevs = points.map((p) => p[2]);
  const minElev = elevs.length ? Math.min(...elevs) : 0;
  const maxElev = elevs.length ? Math.max(...elevs) : 1;
  const span = maxElev - minElev || 1;
  const elevMeters = (elevFt: number): number =>
    baselineMeters == null ? feetToMeters(elevFt - minElev) : feetToMeters(elevFt) - baselineMeters;
  return new ScatterplotLayer<[number, number, number]>({
    id: "lidar-points",
    data: points,
    getPosition: (p) => (threeD ? [p[0], p[1], elevMeters(p[2])] : [p[0], p[1]]),
    updateTriggers: { getPosition: [threeD, baselineMeters] },
    getRadius: 1,
    radiusUnits: "pixels",
    radiusMinPixels: 1,
    radiusMaxPixels: 3,
    getFillColor: (p) => {
      // 0 (lowest) -> light gray; 1 (highest) -> charcoal.
      const t = (p[2] - minElev) / span;
      const c = (lo: number, hi: number) => Math.round(lo + (hi - lo) * t);
      return [
        c(CONFIDENCE_LOW[0], BRAND_CHARCOAL[0]),
        c(CONFIDENCE_LOW[1], BRAND_CHARCOAL[1]),
        c(CONFIDENCE_LOW[2], BRAND_CHARCOAL[2]),
        180,
      ];
    },
    pickable: false,
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
