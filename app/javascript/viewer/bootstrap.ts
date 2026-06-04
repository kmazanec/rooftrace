import type { Root } from "react-dom/client";
import { mountRoofViewer } from "./index";
import type { ViewerPayload } from "./types";

// Self-mounting bootstrap for the esbuild viewer bundle.
//
// The app has no full Stimulus/importmap JS bootstrap wired into the layout, so
// the viewer bundle owns its own lifecycle: on page load it finds the mount
// element (`[data-controller="viewer"]`, the same attribute the documented
// Stimulus controller targets) and mounts the React island, reading the
// serialized measurement payload baked into the data attribute by the server.
// On Turbo navigation away it unmounts to release the WebGL/map context.
//
// The data-controller="viewer" naming keeps this drop-in compatible with a
// future full Stimulus bootstrap: registering viewer_controller.js would mount
// the SAME island via the SAME entry point (mountRoofViewer). Until then this
// bootstrap is the live path.

const MOUNT_SELECTOR = "[data-controller~='viewer']";
const roots = new WeakMap<Element, Root>();

function parsePayload(raw: string | null): ViewerPayload | null {
  if (!raw) return null;
  try {
    return JSON.parse(raw) as ViewerPayload;
  } catch (e) {
    console.error("[viewer] failed to parse measurement payload", e);
    return null;
  }
}

function mountAll(): void {
  document.querySelectorAll<HTMLElement>(MOUNT_SELECTOR).forEach((el) => {
    if (roots.has(el)) return;

    const payload = parsePayload(el.getAttribute("data-viewer-measurement-value"));
    if (!payload) {
      el.textContent = "Interactive viewer unavailable.";
      return;
    }

    const token = el.getAttribute("data-viewer-mapbox-token-value");
    const isPublic = el.getAttribute("data-viewer-public-value") === "true";
    // Empty string (server emits "" when LiDAR isn't available) -> null.
    const lidarPointsUrl = el.getAttribute("data-viewer-lidar-points-url-value") || null;
    const root = mountRoofViewer(el, payload, token, isPublic, lidarPointsUrl);
    roots.set(el, root);
  });
}

function unmountAll(): void {
  document.querySelectorAll<HTMLElement>(MOUNT_SELECTOR).forEach((el) => {
    const root = roots.get(el);
    if (root) {
      root.unmount();
      roots.delete(el);
    }
  });
}

// On a Turbo visit, Turbo injects this <script type="module"> into the new
// <head> AFTER it has already fired turbo:load (and DOMContentLoaded never fires
// on a Turbo visit). A module that only *listens* would register too late to
// catch the event that injected it, so the map stays blank until a full refresh.
// If the document is already parsed by the time we evaluate, mount now.
if (document.readyState !== "loading") {
  mountAll();
}
document.addEventListener("DOMContentLoaded", mountAll);
// Turbo lifecycle: mount on visit, unmount before caching/leaving so deck.gl +
// MapLibre WebGL contexts don't leak across navigations.
document.addEventListener("turbo:load", mountAll);
document.addEventListener("turbo:before-cache", unmountAll);
document.addEventListener("turbo:before-render", unmountAll);

export { mountAll, unmountAll };
