import { PITCH_LIGHTEST, PITCH_DARKEST, RGBA } from "./brandColors";

// Pitch (rise per 12) -> brand neutral-gray RGBA for the facet fill.
//
// The spec leaves the exact scale to this feature; we use documented bucket
// boundaries: pitch 0/12 maps to the lightest gray (#9CA3AF), pitch >= 10/12
// maps to the darkest gray (#374151), interpolating linearly in between.
// LOW pitch = lighter, HIGH pitch = darker — never a stoplight (hue) ramp.
const MAX_RATIO = 10; // 10/12 and above are clamped to the darkest gray.
const DEFAULT_ALPHA = 150; // semi-transparent so the basemap reads through.

function lerp(a: number, b: number, t: number): number {
  return Math.round(a + (b - a) * t);
}

export function colorByPitch(pitchRatio: number, alpha: number = DEFAULT_ALPHA): RGBA {
  const ratio = Number.isFinite(pitchRatio) ? pitchRatio : 0;
  const t = Math.min(Math.max(ratio, 0), MAX_RATIO) / MAX_RATIO;
  return [
    lerp(PITCH_LIGHTEST[0], PITCH_DARKEST[0], t),
    lerp(PITCH_LIGHTEST[1], PITCH_DARKEST[1], t),
    lerp(PITCH_LIGHTEST[2], PITCH_DARKEST[2], t),
    alpha,
  ];
}
