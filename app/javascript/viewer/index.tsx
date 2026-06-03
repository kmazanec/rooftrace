import React from "react";
import { createRoot, Root } from "react-dom/client";
import RoofViewer from "./RoofViewer";
import ErrorBoundary from "./ErrorBoundary";
import type { ViewerPayload } from "./types";

// Entry point the Stimulus viewer_controller lazy-imports on connect. Mounts the
// React island into `el` and returns the root so the controller can unmount on
// Turbo navigation (preventing WebGL/map context leaks).
export function mountRoofViewer(
  el: HTMLElement,
  payload: ViewerPayload,
  mapboxToken: string | null,
  isPublic: boolean,
  lidarPointsUrl: string | null = null
): Root {
  const root = createRoot(el);
  root.render(
    <ErrorBoundary>
      <RoofViewer
        payload={payload}
        mapboxToken={mapboxToken}
        isPublic={isPublic}
        lidarPointsUrl={lidarPointsUrl}
      />
    </ErrorBoundary>
  );
  return root;
}

export default mountRoofViewer;
