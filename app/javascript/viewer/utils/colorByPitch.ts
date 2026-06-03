import { PITCH_LIGHTEST, PITCH_DARKEST, RGBA } from "./brandColors";

// Pitch (rise per 12) -> brand neutral-gray RGBA for the facet fill.
//
// The spec leaves the exact scale to this feature; we use documented bucket
// boundaries: pitch 0/12 maps to the lightest gray (#9CA3AF), pitch >= 10/12
// maps to the darkest gray (#374151), interpolating linearly in between.
// LOW pitch = lighter, HIGH pitch = darker — never a stoplight (hue) ramp.
const MAX_RATIO = 10; // 10/12 and above are clamped to the darkest gray.
const DEFAULT_ALPHA = 150; // semi-transparent so the basemap reads through.

// A distinct neutral for "pitch not measured" — visually separate from the 0/12
// (flat) bucket. Lower alpha than DEFAULT_ALPHA so unknown facets read as ghostly.
export const UNKNOWN_PITCH_RGBA: RGBA = [148, 163, 184, 110];

function lerp(a: number, b: number, t: number): number {
  return Math.round(a + (b - a) * t);
}

export function colorByPitch(pitchRatio: number | null, alpha: number = DEFAULT_ALPHA): RGBA {
  if (pitchRatio == null || !Number.isFinite(pitchRatio)) {
    // alpha param intentionally ignored — unknown facets keep a fixed opacity.
    return UNKNOWN_PITCH_RGBA;
  }
  const t = Math.min(Math.max(pitchRatio, 0), MAX_RATIO) / MAX_RATIO;
  return [
    lerp(PITCH_LIGHTEST[0], PITCH_DARKEST[0], t),
    lerp(PITCH_LIGHTEST[1], PITCH_DARKEST[1], t),
    lerp(PITCH_LIGHTEST[2], PITCH_DARKEST[2], t),
    alpha,
  ];
}
