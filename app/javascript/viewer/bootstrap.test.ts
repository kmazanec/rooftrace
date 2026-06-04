// bootstrap.ts imports mountRoofViewer from "./index", which jest.config.mjs
// maps to a recording stub (__mocks__/viewer-index.js) so this test exercises the
// bootstrap's lifecycle without the React/WebGL graph. The stub records each call
// on its `__calls` array, read here through the same mapped module.
import * as viewerIndex from "./index";

const mountCalls = (viewerIndex as unknown as { __calls: unknown[][] }).__calls;

const PAYLOAD = JSON.stringify({
  address: "123 Main St",
  generated_at: "2026-05-28T00:00:00Z",
  source: "lidar",
  confidence: 0.9,
  total_area_sq_ft: 1684,
  total_perimeter_ft: 168,
  primary_pitch_ratio: 6,
  primary_pitch_degrees: 26.57,
  bounds: [-89.6503, 39.7989, -89.6499, 39.7992],
  facets: [],
  features: [],
  diagnostics: [],
});

function addMountElement(): HTMLElement {
  const el = document.createElement("div");
  el.setAttribute("data-controller", "viewer");
  el.setAttribute("data-viewer-measurement-value", PAYLOAD);
  el.setAttribute("data-viewer-mapbox-token-value", "pk.test");
  el.setAttribute("data-viewer-public-value", "false");
  document.body.appendChild(el);
  return el;
}

beforeEach(() => {
  document.body.innerHTML = "";
  mountCalls.length = 0;
});

// The bug: on a Turbo visit, Turbo injects the viewer <script type="module">
// into the new <head> AFTER it has already fired turbo:load (and DOMContentLoaded
// never fires on a Turbo visit). A module that only LISTENS registers its
// turbo:load/DOMContentLoaded handlers too late to catch the event that injected
// it — so the map never mounts until a full refresh.
//
// jsdom reports document.readyState === "complete" by the time a test runs, which
// is exactly the post-event "DOM already parsed" condition. So importing the
// bootstrap here exercises the same race: a listen-only bootstrap mounts nothing.
test("mounts on import when the document is already loaded (Turbo-injected script)", async () => {
  addMountElement();
  expect(document.readyState).toBe("complete");

  await import("./bootstrap");

  expect(mountCalls).toHaveLength(1);
});

test("mounts on a turbo:load fired after load, and is idempotent", async () => {
  const mod = await import("./bootstrap");
  addMountElement();
  mountCalls.length = 0;

  document.dispatchEvent(new Event("turbo:load"));
  expect(mountCalls).toHaveLength(1);

  // The roots WeakMap guards against re-mounting an element already mounted.
  mod.mountAll();
  expect(mountCalls).toHaveLength(1);
});

test("unmounts before a Turbo navigation to release the WebGL context", async () => {
  const mod = await import("./bootstrap");
  const el = addMountElement();
  mountCalls.length = 0;

  mod.mountAll();
  expect(mountCalls).toHaveLength(1);

  // After unmount, the element is eligible to mount again on the next visit.
  document.dispatchEvent(new Event("turbo:before-cache"));
  mod.mountAll();
  expect(mountCalls).toHaveLength(2);
  void el;
});
