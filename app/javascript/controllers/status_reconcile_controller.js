import { Controller } from "@hotwired/stimulus";

// Reconcile-on-connect for the job status page.
//
// The status page subscribes to a per-job Turbo Stream (turbo_stream_from), and
// Job#advance_to!/#fail_with! broadcast replacements of the _status partial. But
// a fast pipeline can reach a terminal state (failed/ready) BEFORE this page
// finishes establishing its ActionCable subscription — and ActionCable never
// replays a missed message, so the page would freeze on whatever it last
// rendered (e.g. "looking up address").
//
// On connect, if the rendered state is still in-progress, fetch the CURRENT
// status partial once and replace ourselves with it. Future transitions still
// arrive live over the Turbo Stream; this only closes the initial gap.
export default class extends Controller {
  static values = { url: String };

  connect() {
    if (this.#isTerminal()) return;
    this.#reconcile();
  }

  #isTerminal() {
    const status = this.element.dataset.jobStatus;
    return status === "ready" || status === "failed";
  }

  async #reconcile() {
    try {
      const response = await fetch(this.urlValue, {
        headers: { Accept: "text/html" },
        credentials: "same-origin",
      });
      if (!response.ok) return; // leave the live stream to handle it
      const html = await response.text();
      // Only swap if the server's current state differs from what's rendered —
      // avoids a needless DOM churn when the page was already up to date.
      const fresh = new DOMParser().parseFromString(html, "text/html").body.firstElementChild;
      if (fresh && fresh.dataset.jobStatus !== this.element.dataset.jobStatus) {
        this.element.replaceWith(fresh);
      }
    } catch {
      // Network hiccup: the Turbo Stream subscription remains the live path.
    }
  }
}
