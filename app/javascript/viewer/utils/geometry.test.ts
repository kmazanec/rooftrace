import { boundsCenter, featurePinPositions } from "./geometry";
import type { ViewerFeature } from "../types";

describe("boundsCenter", () => {
  it("returns the midpoint of [minLon, minLat, maxLon, maxLat]", () => {
    expect(boundsCenter([-90, 39, -89, 40])).toEqual([-89.5, 39.5]);
  });

  it("returns null for null bounds", () => {
    expect(boundsCenter(null)).toBeNull();
  });
});

describe("featurePinPositions", () => {
  const features: ViewerFeature[] = [
    { label: "chimney", bbox_norm: [0, 0, 0.1, 0.1], verified: true, source: "imagery", confidence: 0.8 },
    { label: "vent", bbox_norm: [0.5, 0.5, 0.6, 0.6], verified: false, source: "imagery", confidence: 0.4 },
  ];

  it("anchors all pins near the roof centroid with a deterministic fan-out", () => {
    const center: [number, number] = [-89.5, 39.5];
    const positions = featurePinPositions(features, center);
    expect(positions).toHaveLength(2);
    // Pins fan out around the centroid, not stacked exactly on it.
    expect(positions[0]).not.toEqual(positions[1]);
    // ...but stay close to the centroid (documented v1 limitation).
    positions.forEach(([lon, lat]) => {
      expect(Math.abs(lon - center[0])).toBeLessThan(0.001);
      expect(Math.abs(lat - center[1])).toBeLessThan(0.001);
    });
  });

  it("returns an empty array when there is no centroid", () => {
    expect(featurePinPositions(features, null)).toEqual([]);
  });
});
