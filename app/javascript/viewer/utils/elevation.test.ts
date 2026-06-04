import { feetToMeters, facetElevationMeters } from "./elevation";

describe("feetToMeters", () => {
  it("converts feet to meters", () => {
    expect(feetToMeters(0)).toBe(0);
    expect(feetToMeters(3.280839895)).toBeCloseTo(1, 6);
    expect(feetToMeters(10)).toBeCloseTo(3.048, 3);
  });
});

describe("facetElevationMeters", () => {
  it("is zero for a flat facet (no pitch)", () => {
    expect(facetElevationMeters({ pitch_ratio: null, area_sq_ft: 800 })).toBe(0);
    expect(facetElevationMeters({ pitch_ratio: 0, area_sq_ft: 800 })).toBe(0);
  });

  it("is zero when the area is missing or non-positive", () => {
    expect(facetElevationMeters({ pitch_ratio: 6, area_sq_ft: 0 })).toBe(0);
    expect(facetElevationMeters({ pitch_ratio: 6, area_sq_ft: -5 })).toBe(0);
  });

  it("rises with a positive pitch", () => {
    expect(facetElevationMeters({ pitch_ratio: 6, area_sq_ft: 842 })).toBeGreaterThan(0);
  });

  it("rises higher for a steeper pitch on the same footprint", () => {
    const shallow = facetElevationMeters({ pitch_ratio: 4, area_sq_ft: 842 });
    const steep = facetElevationMeters({ pitch_ratio: 9, area_sq_ft: 842 });
    expect(steep).toBeGreaterThan(shallow);
  });

  it("rises higher for a larger footprint at the same pitch", () => {
    const small = facetElevationMeters({ pitch_ratio: 6, area_sq_ft: 400 });
    const large = facetElevationMeters({ pitch_ratio: 6, area_sq_ft: 1600 });
    expect(large).toBeGreaterThan(small);
  });
});
