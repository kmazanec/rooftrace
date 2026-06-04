import type { ViewerFacet } from "../types";

// Elevation helpers for the 3D roof view (ADR-013, per-facet elevation by pitch).
//
// deck.gl positions in the default LNGLAT coordinate system carry their z in
// METERS, so every elevation that reaches a layer is converted out of the feet
// the pipeline reports (3DEP LiDAR elevations, derived facet rise) into meters.

const FEET_PER_METER = 3.280839895;

export function feetToMeters(feet: number): number {
  return feet / FEET_PER_METER;
}

// A representative ridge height (meters above the eave) for a single facet,
// derived from its pitch and footprint. We have no per-vertex elevation for the
// measured facets — only the planimetric polygon, its area, and its pitch ratio
// (rise per 12 of run) — so this is a thematic extrusion height: steeper and
// larger facets rise higher, giving the flat polygons a readable 3D massing when
// the camera tilts. A facet with no/zero/negative pitch (flat roof) stays at 0.
//
//   run_ft  ≈ √area              (nominal side of an equivalent square facet)
//   rise_ft  = (run_ft / 2) · (pitch_ratio / 12)   (half-span × slope)
export function facetElevationMeters(facet: Pick<ViewerFacet, "pitch_ratio" | "area_sq_ft">): number {
  const pitch = facet.pitch_ratio;
  const area = facet.area_sq_ft;
  if (pitch == null || pitch <= 0 || !(area > 0)) return 0;

  const runFt = Math.sqrt(area);
  const riseFt = (runFt / 2) * (pitch / 12);
  return feetToMeters(riseFt);
}
