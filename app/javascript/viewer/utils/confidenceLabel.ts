// Confidence (0..1) -> qualitative band, matching the thresholds the side-panel
// ERB uses for the .report-confidence[data-level] muted-gray styling. Kept here
// so the map tooltips and the side panel agree.
export type ConfidenceLevel = "high" | "medium" | "low";

export const LOW_CONFIDENCE_THRESHOLD = 0.6;

export function confidenceLabel(confidence: number): ConfidenceLevel {
  if (confidence >= 0.8) return "high";
  if (confidence >= LOW_CONFIDENCE_THRESHOLD) return "medium";
  return "low";
}

// Below this, a facet renders with the dashed-outline "uncertain reading"
// marker both on the map and in the side panel.
export function isLowConfidence(confidence: number): boolean {
  return confidence < LOW_CONFIDENCE_THRESHOLD;
}
