import { feetToMeters, facetElevationBaseline, groundBaselineMeters } from "./elevation";
import type { ViewerFacet } from "../types";

function facet(vertices: ViewerFacet["vertices"]): ViewerFacet {
  return {
    facet_id: "F",
    vertices,
    pitch_ratio: 6,
    pitch_degrees: 26.57,
    area_sq_ft: 800,
    source: "lidar",
    confidence: 0.9,
  };
}

describe("feetToMeters", () => {
  it("converts feet to meters", () => {
    expect(feetToMeters(0)).toBe(0);
    expect(feetToMeters(3.280839895)).toBeCloseTo(1, 6);
    expect(feetToMeters(10)).toBeCloseTo(3.048, 3);
  });
});

describe("facetElevationBaseline", () => {
  it("is null when no facet vertex carries an elevation", () => {
    expect(
      facetElevationBaseline([
        facet([
          [-89.65, 39.79],
          [-89.64, 39.79],
          [-89.64, 39.8],
        ]),
      ])
    ).toBeNull();
  });

  it("is the lowest elevation across all facet vertices", () => {
    const baseline = facetElevationBaseline([
      facet([
        [-89.65, 39.79, 251.4],
        [-89.64, 39.79, 254.9],
        [-89.64, 39.8, 252.0],
      ]),
      facet([
        [-89.64, 39.79, 250.1],
        [-89.63, 39.79, 253.2],
        [-89.63, 39.8, 255.0],
      ]),
    ]);
    expect(baseline).toBeCloseTo(250.1, 6);
  });

  it("ignores vertices that lack an elevation", () => {
    const baseline = facetElevationBaseline([
      facet([
        [-89.65, 39.79], // no z
        [-89.64, 39.79, 260.0],
        [-89.64, 39.8, 262.0],
      ]),
    ]);
    expect(baseline).toBeCloseTo(260.0, 6);
  });
});

describe("groundBaselineMeters", () => {
  const roofFacets = [
    facet([
      [-89.65, 39.79, 322.29], // eave (lowest facet vertex, metres)
      [-89.64, 39.79, 325.86], // ridge
      [-89.64, 39.8, 322.73],
    ]),
  ];

  it("uses the facet eave when no LiDAR points are loaded", () => {
    expect(groundBaselineMeters(roofFacets, null)).toBeCloseTo(322.29, 6);
  });

  it("drops to the true ground (lowest LiDAR point) when points reach below the eave", () => {
    // 1046.7 ft ≈ 319.03 m — ~3.3 m below the eave, the real ground the cloud sees.
    const lidarFt: [number, number, number][] = [
      [-89.645, 39.795, 1046.7], // ground
      [-89.645, 39.795, 1068.9], // ridge
    ];
    expect(groundBaselineMeters(roofFacets, lidarFt)).toBeCloseTo(feetToMeters(1046.7), 6);
  });

  it("keeps the facet eave when every LiDAR point sits above it", () => {
    const lidarFt: [number, number, number][] = [[-89.645, 39.795, 1070.0]];
    expect(groundBaselineMeters(roofFacets, lidarFt)).toBeCloseTo(322.29, 6);
  });

  it("falls back to LiDAR alone when facets carry no elevation", () => {
    const flat = [
      facet([
        [-89.65, 39.79],
        [-89.64, 39.79],
        [-89.64, 39.8],
      ]),
    ];
    const lidarFt: [number, number, number][] = [[-89.645, 39.795, 1046.7]];
    expect(groundBaselineMeters(flat, lidarFt)).toBeCloseTo(feetToMeters(1046.7), 6);
  });

  it("is null when there is nothing to anchor to", () => {
    const flat = [
      facet([
        [-89.65, 39.79],
        [-89.64, 39.79],
        [-89.64, 39.8],
      ]),
    ];
    expect(groundBaselineMeters(flat, null)).toBeNull();
    expect(groundBaselineMeters(flat, [])).toBeNull();
  });
});
