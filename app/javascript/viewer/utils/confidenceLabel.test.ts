import { confidenceLabel, isLowConfidence } from "./confidenceLabel";

describe("confidenceLabel", () => {
  it("labels >= 0.8 as high", () => {
    expect(confidenceLabel(0.9)).toBe("high");
    expect(confidenceLabel(0.8)).toBe("high");
    expect(confidenceLabel(1)).toBe("high");
  });

  it("labels 0.6..0.8 as medium", () => {
    expect(confidenceLabel(0.6)).toBe("medium");
    expect(confidenceLabel(0.79)).toBe("medium");
  });

  it("labels < 0.6 as low", () => {
    expect(confidenceLabel(0.59)).toBe("low");
    expect(confidenceLabel(0)).toBe("low");
  });

  it("treats < 0.6 as low-confidence for the dashed-outline marker", () => {
    expect(isLowConfidence(0.5)).toBe(true);
    expect(isLowConfidence(0.6)).toBe(false);
    expect(isLowConfidence(0.9)).toBe(false);
  });
});
