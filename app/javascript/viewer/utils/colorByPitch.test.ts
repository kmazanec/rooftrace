import { colorByPitch, UNKNOWN_PITCH_RGBA } from "./colorByPitch";
import { PITCH_LIGHTEST, PITCH_DARKEST } from "./brandColors";

describe("colorByPitch", () => {
  it("maps a flat (0/12) pitch to the lightest brand gray", () => {
    const [r, g, b] = colorByPitch(0);
    expect([r, g, b]).toEqual(PITCH_LIGHTEST);
  });

  it("maps a steep (>=10/12) pitch to the darkest brand gray", () => {
    const [r, g, b] = colorByPitch(10);
    expect([r, g, b]).toEqual(PITCH_DARKEST);
    const [r2, g2, b2] = colorByPitch(14);
    expect([r2, g2, b2]).toEqual(PITCH_DARKEST); // clamped, never overshoots
  });

  it("interpolates monotonically darker as pitch rises", () => {
    const low = colorByPitch(2)[0];
    const mid = colorByPitch(6)[0];
    const high = colorByPitch(10)[0];
    // R channel decreases (gets darker) as pitch rises.
    expect(low).toBeGreaterThan(mid);
    expect(mid).toBeGreaterThan(high);
  });

  it("returns a 4-tuple RGBA with the supplied alpha", () => {
    const c = colorByPitch(6, 180);
    expect(c).toHaveLength(4);
    expect(c[3]).toBe(180);
  });

  it("defaults to an opaque-ish fill alpha", () => {
    expect(colorByPitch(6)[3]).toBeGreaterThan(0);
  });

  it("never produces stoplight colors (R, G, B stay within the gray ramp)", () => {
    for (let ratio = 0; ratio <= 12; ratio += 1) {
      const [r, g, b] = colorByPitch(ratio);
      // Grays have R~G~B; assert channels are close (within the ramp spread).
      expect(Math.abs(r - g)).toBeLessThan(40);
      expect(Math.abs(g - b)).toBeLessThan(40);
    }
  });
});

describe("colorByPitch unknown pitch", () => {
  it("returns a distinct UNKNOWN color for null pitch (not the 0/12 bucket)", () => {
    const unknown = colorByPitch(null);
    const flat = colorByPitch(0);
    expect(unknown).not.toEqual(flat);
    expect([unknown[0], unknown[1], unknown[2]]).toEqual([UNKNOWN_PITCH_RGBA[0], UNKNOWN_PITCH_RGBA[1], UNKNOWN_PITCH_RGBA[2]]);
  });

  it("still ramps a real pitch", () => {
    expect(colorByPitch(6)).not.toEqual(colorByPitch(0));
  });
});
