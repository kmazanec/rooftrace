// Brand color constants mirroring app/assets/tailwind/brand.css. The viewer
// island cannot read CSS custom properties for WebGL fill colors, so the
// load-bearing grays are duplicated here as RGB tuples. Keep IN SYNC with
// brand.css — these are the SAME hex values, not new tokens.
export type RGB = [number, number, number];
export type RGBA = [number, number, number, number];

// Confidence grays (vary by value, never hue — never stoplight).
export const CONFIDENCE_HIGH: RGB = [0x37, 0x41, 0x51]; // #374151 dark gray
export const CONFIDENCE_MEDIUM: RGB = [0x6b, 0x72, 0x80]; // #6B7280 mid gray
export const CONFIDENCE_LOW: RGB = [0x9c, 0xa3, 0xaf]; // #9CA3AF light gray

// Pitch ramp endpoints: low pitch -> lighter gray, high pitch -> darker gray
// (brand neutral grays, NOT a stoplight ramp).
export const PITCH_LIGHTEST: RGB = [0x9c, 0xa3, 0xaf]; // #9CA3AF gray-400
export const PITCH_DARKEST: RGB = [0x37, 0x41, 0x51]; // #374151 gray-700

export const BRAND_CHARCOAL: RGB = [0x1c, 0x1c, 0x1e]; // #1C1C1E
export const BRAND_ORANGE: RGB = [0xff, 0x6a, 0x1f]; // #FF6A1F
