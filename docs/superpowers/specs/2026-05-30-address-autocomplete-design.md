# Address autocomplete on the entry screen (Mapbox Search Box)

Date: 2026-05-30
Status: Approved for build (user delegated decisions — "make reasonable assumptions, build it")

## Problem

The address-entry screen (`app/views/jobs/new.html.erb`, route `root → jobs#new`)
is a bare text field. Contractors type a full address by hand with no
suggestions, so typos and malformed addresses flow straight into the pipeline,
where the first stage (Nominatim geocode) 422s on a bad string. We want
type-ahead address suggestions so the contractor picks a real, well-formed
address before submitting.

## The provider constraint (this is the whole design)

**Geocoding and imagery are two different Mapbox surfaces in this repo, and
they are not the same thing as the *authoritative* geocoder.**

- Imagery (satellite tiles) → Mapbox (ADR-002). Token already present:
  `MAPBOX_PUBLIC_TOKEN` (front-end pk.* token) + a server-side imagery token.
- Authoritative geocode (typed address → lat/lon that the pipeline persists and
  caches for 30 days) → **Nominatim**, deliberately, per **ADR-005**.

ADR-005 explicitly **rejected Mapbox for geocoding** because Mapbox's ToS forbids
storing/caching geocode results *unless a Mapbox map is displayed in the same
session*, and the pipeline caches geocodes for 30 days. That rejection still
holds for the *authoritative, persisted* geocode.

It does **not** forbid using Mapbox for **interactive, in-session, non-persisted
autocomplete suggestions** — that is exactly the use case Mapbox's Search Box API
is licensed for (session-based, the suggestions are ephemeral UI state, nothing
is stored server-side). So:

> **Mapbox powers the typeahead suggestions in the browser only. Nominatim
> remains the authoritative geocoder. We never persist a Mapbox suggestion as the
> geocode.** When the contractor picks a suggestion we submit its *address text*
> (and only that) through the existing form; the pipeline re-geocodes that clean
> string with Nominatim exactly as today.

This keeps ADR-005 intact (amended, not reversed): better input quality, no ToS
violation, no second authoritative geocoder, no change to caching/attribution in
the pipeline.

## Approach chosen

**Mapbox Search Box API, called from the browser, proxied through a thin Rails
endpoint** — not called directly from JS with the public token, and not called
from the sidecar.

Three options were weighed:

1. **Browser → Mapbox directly with `MAPBOX_PUBLIC_TOKEN`.** Simplest, but (a)
   leaks our token into every keystroke request's URL from random contractor
   networks, (b) the imagery token's URL-restriction scoping would have to be
   widened to allow the Search Box endpoint, (c) no server-side place to enforce
   `country=us`, session reuse, or rate limiting. Rejected.
2. **Browser → Rails proxy → Mapbox (chosen).** Rails holds the token
   server-side, injects `country=us` + `types` + a per-browser-session token,
   and returns a trimmed JSON list. One small controller, CSP stays `:self`, the
   token never reaches the client. Costs one extra hop (localhost-fast).
3. **Browser → Rails → sidecar → Mapbox.** The sidecar is the geometry service
   (ADR-008 boundary: Rails owns HTTP/auth, Python owns geometry). Autocomplete
   is neither geometry nor pipeline work, and the sidecar is internal-only with
   no contractor-facing surface. Putting a UI-latency-sensitive typeahead behind
   the internal hop is the wrong layer. Rejected.

## Components

### 1. Rails proxy endpoint — `GET /address_suggestions?q=...`
- New controller `AddressSuggestionsController#index`, gated by
  `require_demo_login` like the rest of the contractor surface.
- Calls Mapbox Search Box **`/suggest`** with the server-side token,
  `country=us`, `types=address`, `language=en`, and a `session_token` (see
  session handling below). Returns `limit` ≤ 6.
- Maps Mapbox's response to a minimal JSON array the client needs:
  `[{ name, mapbox_id, place_formatted }]`. We do **not** call `/retrieve`
  (which returns coordinates) — we never need Mapbox coordinates, because
  Nominatim re-geocodes. We only need the display text the user picks. This also
  keeps us clearly inside "suggest-only, nothing stored."
- Failure handling: any Mapbox error / timeout / missing token →
  **HTTP 200 with `{ "suggestions": [] }`**, logged server-side. Autocomplete is
  a progressive enhancement; it must never block typing or break the form. (The
  field still works as a plain text input with no suggestions.)
- New env var `MAPBOX_SEARCH_TOKEN`. Falls back to the existing server-side
  imagery token if you choose to reuse it, but a distinct var is documented so
  the Search Box scope can be granted independently. Boot behaviour mirrors the
  other Mapbox initializers: **warn in dev/test, do not hard-fail** (autocomplete
  degrades gracefully, unlike imagery which is load-bearing). No `raise` in prod
  either — a missing autocomplete token must not take down `/health` or boot,
  because the form is fully functional without it.

### 2. Stimulus controller — `address_autocomplete_controller.js`
- Registered in `controllers/index.js` (the importmap/Hotwire path — NOT the
  esbuild viewer island; this is a plain Hotwire page, so it follows
  `status_reconcile_controller`'s pattern exactly).
- Targets: the `input` (the existing address field) and a `listbox` (a `<ul>`
  rendered empty in the view).
- Behaviour: debounce input (~250 ms), require ≥ 4 chars, `fetch` the proxy,
  render suggestions into the listbox. Click / Enter / Arrow-key selection fills
  the input with the chosen `name` and closes the listbox. Escape / blur closes.
- Accessibility: WAI-ARIA combobox pattern — `role="combobox"`,
  `aria-expanded`, `aria-controls`, `aria-activedescendant`;
  `role="listbox"`/`role="option"` on the list. Keyboard fully operable.
- Pure progressive enhancement: if JS is off or the fetch fails, the field is an
  ordinary text input and the form submits exactly as today.

### 3. View change — `app/views/jobs/new.html.erb`
- Wrap the existing field in the combobox markup, add `data-controller` +
  `data-*-target` attributes and the (initially empty) listbox `<ul>`.
- The submit path is **unchanged**: `form_with model: @job, url: jobs_path`
  still posts `job[address]` as free text. Selecting a suggestion only sets the
  input's value. No new params, no controller change in `JobsController`.

### 4. Styling
- Add listbox/option styles to the `cc` stylesheet (the entry-surface palette,
  `cc-*`, per the two-palette rule — entry screen is CompanyCam-blue, never the
  report/brand palette). Match existing `cc-input` / `cc-field` look.

## Session token handling (Mapbox billing correctness)

Mapbox Search Box bills a "session" = N `/suggest` calls + one `/retrieve`,
keyed by a `session_token` (a client-generated UUID). Because we deliberately
**never call `/retrieve`**, each of our sessions is suggest-only. We still pass a
`session_token` per browser typing session (the Stimulus controller generates a
UUID on connect and sends it as a query param the proxy forwards) so Mapbox
groups the keystroke calls into one session for billing/analytics rather than
counting each keystroke as a standalone request.

## Data flow

```
contractor types ≥4 chars
  → Stimulus debounces 250ms
  → GET /address_suggestions?q=...&session_token=<uuid>   (same-origin, cookie-authed)
  → AddressSuggestionsController → Mapbox /suggest (server token, country=us, types=address)
  → trim to [{name, mapbox_id, place_formatted}]
  → JSON back to browser
  → Stimulus renders listbox
contractor picks one
  → input.value = suggestion.name   (nothing persisted, no /retrieve)
contractor submits form (unchanged)
  → POST /jobs job[address]=<clean text>
  → pipeline geocodes with NOMINATIM (authoritative, ADR-005) exactly as today
```

## Error handling

| Failure | Behaviour |
| --- | --- |
| `MAPBOX_SEARCH_TOKEN` unset | boot warns (dev/test/prod); proxy returns `{suggestions: []}`; field works as plain text |
| Mapbox 4xx/5xx/timeout | proxy logs, returns `{suggestions: []}` 200; typing unaffected |
| JS disabled / fetch fails | plain text field, form submits as today |
| User ignores suggestions, types freely | free text submitted, Nominatim geocodes it (today's behaviour) |
| Empty / <4-char query | proxy returns `{suggestions: []}` without calling Mapbox |

## Testing

- **Request spec** `spec/requests/address_suggestions_spec.rb`: auth required;
  Mapbox HTTP **stubbed with WebMock** (no live calls in suite) — happy path maps
  fields correctly; Mapbox-error path returns `{suggestions: []}` 200;
  missing-token path returns `{suggestions: []}` 200; short/empty `q` short-
  circuits without hitting Mapbox.
- **Jobs request spec**: assert `new.html.erb` renders the combobox markup
  (`data-controller="address-autocomplete"`) and that a normal POST still creates
  the job (regression — submit path unchanged).
- **JS unit (vitest)** `address_autocomplete_controller.test.js`: debounce,
  ≥4-char gate, listbox render from a mocked fetch, selection fills input,
  keyboard nav + Escape close. (Mirrors the existing vitest setup used by the
  viewer.)
- No live Mapbox call anywhere in the suite (consistent with the repo's
  "stub external HTTP in tests" convention; real path is the default only in the
  running app).

## ADR / docs updates

- **Amend ADR-005** with an "Autocomplete (amended 2026-05)" section: Nominatim
  remains the authoritative geocoder; Mapbox Search Box `/suggest` provides
  in-session, non-persisted typeahead only; we never call `/retrieve` and never
  store a Mapbox geocode, so the ToS caching restriction that drove the original
  Nominatim decision is not triggered. (Amend at source — repo convention.)
- `.env.example`: document `MAPBOX_SEARCH_TOKEN`.
- No change to ROADMAP/ARCHITECTURE beyond the ADR amendment (scoped feature).

## Out of scope (YAGNI)

- Calling Mapbox `/retrieve` / using Mapbox coordinates anywhere.
- Replacing Nominatim as the authoritative geocoder.
- Reverse geocoding, map-pin refinement, parcel preview on the entry screen.
- Caching suggestions server-side (would re-introduce the ToS problem).
- Non-US address support (pipeline is US-only today; `country=us`).
```
