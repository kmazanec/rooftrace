import { feetToMeters, facetElevationBaseline } from "./elevation";
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
