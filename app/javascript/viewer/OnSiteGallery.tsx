import React, { useState } from "react";
import type { OnSiteVisualization } from "./types";

// The "On-Site Visualization" gallery (ADR-019): a swipeable strip of composite
// images (the measured roof projected onto each captured photo). Surfaced below
// the map in the report viewer.
//
// Cross-highlight (in scope for v1): the gallery and the map share a selected
// gallery index. Selecting a gallery item bubbles up via onSelect so the map can
// react (e.g. flash a "showing photo N" badge); a parent-driven activeIndex
// drives the gallery the other way. A low_pose_confidence visualization shows a
// warning instead of a (misregistered) composite, never a broken overlay.

interface Props {
  visualizations: OnSiteVisualization[];
  // Notify the parent when a gallery item is selected (for map cross-highlight).
  onSelect?: (index: number) => void;
}

export default function OnSiteGallery({ visualizations, onSelect }: Props) {
  const [active, setActive] = useState(0);

  // Render nothing when there are no visualizations (the section is omitted).
  const usable = visualizations.filter(
    (v) => v.composite_url || v.low_pose_confidence
  );
  if (usable.length === 0) return null;

  const select = (i: number) => {
    setActive(i);
    onSelect?.(i);
  };

  const current = usable[active];

  return (
    <div data-testid="on-site-gallery" className="on-site-gallery">
      <h3 className="on-site-gallery__title">On-Site Visualization</h3>

      <div className="on-site-gallery__stage" data-testid="on-site-gallery-stage">
        {current.low_pose_confidence || !current.composite_url ? (
          <p
            data-testid="low-pose-warning"
            role="status"
            className="on-site-gallery__warning"
          >
            This on-site photo couldn&rsquo;t be aligned confidently enough to draw
            the measurements on it.
          </p>
        ) : (
          <img
            src={current.composite_url}
            alt={current.caption ?? "On-site visualization"}
            data-testid="on-site-composite"
            className="on-site-gallery__image"
          />
        )}
        {current.caption && (
          <p className="on-site-gallery__caption">{current.caption}</p>
        )}
      </div>

      <div className="on-site-gallery__thumbs" role="tablist">
        {usable.map((viz, i) => (
          <button
            key={i}
            type="button"
            role="tab"
            aria-selected={i === active}
            data-testid={`on-site-thumb-${i}`}
            className={
              "on-site-gallery__thumb" +
              (i === active ? " on-site-gallery__thumb--active" : "")
            }
            onClick={() => select(i)}
          >
            {viz.composite_url ? (
              <img src={viz.composite_url} alt="" aria-hidden="true" />
            ) : (
              <span aria-hidden="true">!</span>
            )}
          </button>
        ))}
      </div>
    </div>
  );
}
