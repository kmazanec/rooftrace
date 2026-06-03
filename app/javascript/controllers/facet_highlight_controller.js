import { Controller } from "@hotwired/stimulus";

// Bridges hover between the server-rendered facet table and the React map island
// (ADR-013 keeps them decoupled — the table is Hotwire ERB, the map is an esbuild
// React bundle). Both sides speak one window-level CustomEvent, "roof:facet-hover"
// with detail { facetId: string | null, origin: "table" | "map" }:
//
//   - The map dispatches it on facet hover; this controller highlights the
//     matching table row.
//   - This controller dispatches it on table-row hover; the map highlights the
//     matching polygon.
//
// `origin` lets each side ignore its own echo so a hover doesn't loop.
export default class extends Controller {
  connect() {
    this.onExternalHover = this.onExternalHover.bind(this);
    window.addEventListener("roof:facet-hover", this.onExternalHover);

    // Delegate row hover so it works regardless of how many facets render.
    this.onRowOver = this.onRowOver.bind(this);
    this.onRowOut = this.onRowOut.bind(this);
    this.element.addEventListener("mouseover", this.onRowOver);
    this.element.addEventListener("mouseout", this.onRowOut);
  }

  disconnect() {
    window.removeEventListener("roof:facet-hover", this.onExternalHover);
    this.element.removeEventListener("mouseover", this.onRowOver);
    this.element.removeEventListener("mouseout", this.onRowOut);
  }

  onExternalHover(event) {
    if (event.detail?.origin === "table") return; // ignore our own echo
    this.setActive(event.detail?.facetId ?? null);
  }

  onRowOver(event) {
    const row = event.target.closest(".report-facet-row");
    if (!row) return;
    const facetId = row.dataset.facetId ?? null;
    this.setActive(facetId);
    this.emit(facetId);
  }

  onRowOut(event) {
    const row = event.target.closest(".report-facet-row");
    if (!row) return;
    // Only clear when the pointer actually left the row (not moving between its
    // own child cells).
    if (row.contains(event.relatedTarget)) return;
    this.setActive(null);
    this.emit(null);
  }

  setActive(facetId) {
    this.element.querySelectorAll(".report-facet-row.is-active").forEach((r) => {
      r.classList.remove("is-active");
    });
    if (!facetId) return;
    const row = this.element.querySelector(
      `.report-facet-row[data-facet-id="${CSS.escape(facetId)}"]`
    );
    row?.classList.add("is-active");
  }

  emit(facetId) {
    window.dispatchEvent(
      new CustomEvent("roof:facet-hover", {
        detail: { facetId, origin: "table" },
      })
    );
  }
}
