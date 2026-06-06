import { Controller } from "@hotwired/stimulus";

// Bridges the server-rendered facet table and the React map island (ADR-013 keeps
// them decoupled — the table is Hotwire ERB, the map is an esbuild React bundle).
// Both sides speak window-level CustomEvents with detail { facetId, origin }:
//
//   - "roof:facet-hover" — transient. Map hover / row hover; cleared on leave.
//   - "roof:facet-pin"   — sticky. Map click / row click; the facet stays
//     highlighted until click-away or another facet is selected.
//
// Each surface tags its `origin` ("table" | "map") and ignores its own echo so a
// hover/click doesn't loop. The table mirrors hover with `.is-active` and the pin
// with `.is-pinned`; the map renders the same facet blue (see RoofViewer).
export default class extends Controller {
  connect() {
    this.onExternalHover = this.onExternalHover.bind(this);
    this.onExternalPin = this.onExternalPin.bind(this);
    window.addEventListener("roof:facet-hover", this.onExternalHover);
    window.addEventListener("roof:facet-pin", this.onExternalPin);

    // Delegate row events so they work regardless of how many facets render.
    this.onRowOver = this.onRowOver.bind(this);
    this.onRowOut = this.onRowOut.bind(this);
    this.onRowClick = this.onRowClick.bind(this);
    this.element.addEventListener("mouseover", this.onRowOver);
    this.element.addEventListener("mouseout", this.onRowOut);
    this.element.addEventListener("click", this.onRowClick);
  }

  disconnect() {
    window.removeEventListener("roof:facet-hover", this.onExternalHover);
    window.removeEventListener("roof:facet-pin", this.onExternalPin);
    this.element.removeEventListener("mouseover", this.onRowOver);
    this.element.removeEventListener("mouseout", this.onRowOut);
    this.element.removeEventListener("click", this.onRowClick);
  }

  onExternalHover(event) {
    if (event.detail?.origin === "table") return; // ignore our own echo
    this.setActive(event.detail?.facetId ?? null);
  }

  onExternalPin(event) {
    if (event.detail?.origin === "table") return; // ignore our own echo
    this.setPinned(event.detail?.facetId ?? null);
  }

  onRowOver(event) {
    const row = event.target.closest(".report-facet-row");
    if (!row) return;
    const facetId = row.dataset.facetId ?? null;
    this.setActive(facetId);
    this.emitHover(facetId);
  }

  onRowOut(event) {
    const row = event.target.closest(".report-facet-row");
    if (!row) return;
    // Only clear when the pointer actually left the row (not moving between its
    // own child cells).
    if (row.contains(event.relatedTarget)) return;
    this.setActive(null);
    this.emitHover(null);
  }

  onRowClick(event) {
    const row = event.target.closest(".report-facet-row");
    const facetId = row ? row.dataset.facetId ?? null : null;
    this.setPinned(facetId);
    this.emitPin(facetId);
  }

  setActive(facetId) {
    this.toggleClass("is-active", facetId);
  }

  setPinned(facetId) {
    this.toggleClass("is-pinned", facetId);
  }

  toggleClass(className, facetId) {
    this.element.querySelectorAll(`.report-facet-row.${className}`).forEach((r) => {
      r.classList.remove(className);
    });
    if (!facetId) return;
    const row = this.element.querySelector(
      `.report-facet-row[data-facet-id="${CSS.escape(facetId)}"]`
    );
    row?.classList.add(className);
  }

  emitHover(facetId) {
    this.dispatch("roof:facet-hover", facetId);
  }

  emitPin(facetId) {
    this.dispatch("roof:facet-pin", facetId);
  }

  dispatch(name, facetId) {
    window.dispatchEvent(new CustomEvent(name, { detail: { facetId, origin: "table" } }));
  }
}
