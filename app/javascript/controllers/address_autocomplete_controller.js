// Address-entry typeahead (ADR-004 amended). Debounces the address field,
// fetches suggestions from the same-origin /address_suggestions proxy (which
// calls Mapbox Search Box /suggest server-side), and renders a WAI-ARIA
// combobox listbox. Selecting a suggestion only fills the input — nothing is
// persisted and the form still submits free text, so Nominatim remains the
// authoritative geocoder.
//
// Pure progressive enhancement: every failure path leaves the input working as
// a plain text field. Registered via the importmap/Hotwire path in
// controllers/index.js (NOT the esbuild viewer island — see that file's note).
import { Controller } from "@hotwired/stimulus";

const DEBOUNCE_MS = 250;
const MIN_CHARS = 4;

export default class extends Controller {
  static targets = ["input", "listbox"];
  static values = { url: String };

  connect() {
    this.sessionToken = this.#uuid();
    this.activeIndex = -1;
    this.suggestions = [];
    this._timer = null;
    this._onDocClick = (e) => {
      if (!this.element.contains(e.target)) this.close();
    };
    document.addEventListener("click", this._onDocClick);
  }

  disconnect() {
    document.removeEventListener("click", this._onDocClick);
    if (this._timer) clearTimeout(this._timer);
  }

  onInput() {
    if (this._timer) clearTimeout(this._timer);
    const q = this.inputTarget.value.trim();
    if (q.length < MIN_CHARS) {
      this.close();
      return;
    }
    this._timer = setTimeout(() => this.#fetch(q), DEBOUNCE_MS);
  }

  onKeydown(event) {
    if (this.listboxTarget.hidden) return;
    switch (event.key) {
      case "ArrowDown":
        event.preventDefault();
        this.#move(1);
        break;
      case "ArrowUp":
        event.preventDefault();
        this.#move(-1);
        break;
      case "Enter":
        if (this.activeIndex >= 0) {
          event.preventDefault();
          this.#select(this.activeIndex);
        }
        break;
      case "Escape":
        this.close();
        break;
    }
  }

  close() {
    this.listboxTarget.hidden = true;
    this.listboxTarget.innerHTML = "";
    this.activeIndex = -1;
    this.suggestions = [];
    this.inputTarget.setAttribute("aria-expanded", "false");
    this.inputTarget.removeAttribute("aria-activedescendant");
  }

  async #fetch(q) {
    const url = new URL(this.urlValue, window.location.origin);
    url.searchParams.set("q", q);
    url.searchParams.set("session_token", this.sessionToken);
    try {
      const res = await fetch(url, { headers: { Accept: "application/json" } });
      if (!res.ok) return this.close();
      const data = await res.json();
      this.#render(data.suggestions || []);
    } catch {
      this.close();
    }
  }

  #render(suggestions) {
    this.suggestions = suggestions;
    this.activeIndex = -1;
    if (suggestions.length === 0) {
      this.close();
      return;
    }
    this.listboxTarget.innerHTML = "";
    suggestions.forEach((s, i) => {
      const li = document.createElement("li");
      li.className = "cc-autocomplete__option";
      li.id = `address-suggestion-${i}`;
      li.setAttribute("role", "option");
      li.setAttribute("aria-selected", "false");
      const name = document.createElement("span");
      name.className = "cc-autocomplete__name";
      name.textContent = s.name;
      li.appendChild(name);
      if (s.place_formatted) {
        const ctx = document.createElement("span");
        ctx.className = "cc-autocomplete__context";
        ctx.textContent = s.place_formatted;
        li.appendChild(ctx);
      }
      li.addEventListener("mousedown", (e) => {
        // mousedown (not click) so it fires before the input's blur.
        e.preventDefault();
        this.#select(i);
      });
      this.listboxTarget.appendChild(li);
    });
    this.listboxTarget.hidden = false;
    this.inputTarget.setAttribute("aria-expanded", "true");
  }

  #move(delta) {
    const n = this.suggestions.length;
    if (n === 0) return;
    this.activeIndex = (this.activeIndex + delta + n) % n;
    Array.from(this.listboxTarget.children).forEach((li, i) => {
      const active = i === this.activeIndex;
      li.classList.toggle("is-active", active);
      li.setAttribute("aria-selected", active ? "true" : "false");
    });
    this.inputTarget.setAttribute(
      "aria-activedescendant",
      `address-suggestion-${this.activeIndex}`
    );
  }

  #select(index) {
    const s = this.suggestions[index];
    if (!s) return;
    // Fill the field with the full address text. We intentionally do NOT use any
    // Mapbox coordinates — the pipeline re-geocodes this string with Nominatim.
    this.inputTarget.value = s.place_formatted
      ? `${s.name}, ${s.place_formatted}`
      : s.name;
    this.close();
    this.inputTarget.focus();
  }

  #uuid() {
    if (window.crypto && window.crypto.randomUUID) return window.crypto.randomUUID();
    // Fallback for older browsers (allow_browser :modern means this is rare).
    return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => {
      const r = (Math.random() * 16) | 0;
      const v = c === "x" ? r : (r & 0x3) | 0x8;
      return v.toString(16);
    });
  }
}
