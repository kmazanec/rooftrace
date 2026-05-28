import type { ViewerFeature } from "../types";

export type Bounds = [number, number, number, number]; // [minLon,minLat,maxLon,maxLat]
export type LngLat = [number, number];

export function boundsCenter(bounds: Bounds | null): LngLat | null {
  if (!bounds) return null;
  return [(bounds[0] + bounds[2]) / 2, (bounds[1] + bounds[3]) / 2];
}

// Detected Features carry only bbox_norm (image-space [0,1] against the
// satellite tile) — the orchestrator emits NO geographic center. v1 therefore
// anchors every feature pin near the roof centroid with a small deterministic
// fan-out so overlapping pins stay individually clickable, and surfaces the
// real inventory in the side-panel features table. This is a DOCUMENTED v1
// limitation (precise geolocation needs the orchestrator to emit feature
// lon/lat — flagged as a cross-cutting follow-up). We never fabricate
// per-feature coordinates from bbox_norm.
const FAN_RADIUS_DEG = 0.00005; // ~5m at mid latitudes; keeps pins on the roof.

export function featurePinPositions(
  features: ViewerFeature[],
  center: LngLat | null
): LngLat[] {
  if (!center) return [];
  const n = features.length;
  if (n === 0) return [];
  if (n === 1) return [center];

  return features.map((_, i) => {
    const angle = (2 * Math.PI * i) / n;
    return [
      center[0] + Math.cos(angle) * FAN_RADIUS_DEG,
      center[1] + Math.sin(angle) * FAN_RADIUS_DEG,
    ];
  });
}
