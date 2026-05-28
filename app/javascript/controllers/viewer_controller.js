import { Controller } from "@hotwired/stimulus";

// Documented Stimulus integration path for the React report-viewer island.
//
// The viewer's live mount path today is the self-mounting esbuild bundle
// (app/javascript/viewer/bootstrap.ts), which targets the SAME
// data-controller="viewer" element and reads the SAME data-viewer-* values.
// This controller exists so that if/when a full Stimulus bootstrap is wired into
// the layout, the island mounts through the idiomatic Stimulus lifecycle
// instead — connect() lazy-imports the bundle entry and mounts; disconnect()
// unmounts so Turbo navigations don't leak the deck.gl/MapLibre WebGL context.
//
// To activate this path: register it in app/javascript/controllers/index.js and
// stop the bundle from self-mounting (guard bootstrap.ts on a data flag). Until
// then the bundle owns the lifecycle and this file is the reference contract.
export default class extends Controller {
  static values = { measurement: Object, mapboxToken: String, public: Boolean };

  async connect() {
    if (!this.hasMeasurementValue || Object.keys(this.measurementValue).length === 0) {
      this.element.textContent = "Interactive viewer unavailable.";
      return;
    }
    const { mountRoofViewer } = await import("../viewer/index");
    this.root = mountRoofViewer(
      this.element,
      this.measurementValue,
      this.mapboxTokenValue || null,
      this.publicValue
    );
  }

  disconnect() {
    if (this.root) {
      this.root.unmount();
      this.root = null;
    }
  }
}
