# Feature: Brand assets + shared report stylesheet

**ID:** F-04 · **Roadmap piece:** F-04 · **Status:** Done (2026-05-28)

## Description

Ships the visual design contract for RoofTrace as concrete assets and
a shared stylesheet consumed by both the web viewer (F-12) and the
PDF report (F-13). Anchors the construction-document /
contractor-respectful aesthetic from [COMPANY.md §Brand & voice](../COMPANY.md)
so every subsequent surface ships on-brand from day one rather than
discovering a brand drift in code review.

Per COMPANY.md and [ADR-018](../adrs/ADR-018-stretch-insurance-claim-pdf.md),
the RoofTrace mark is a *near-but-distinct* riff on CompanyCam's
hi-viz-orange / monochrome aesthetic — the demo should look like
CompanyCam would have built this, without literally appropriating
their wordmark.

## How it fits the roadmap

Wave 1 — parallel with F-02 (contract) and F-03 (auth). Unblocks the
two user-facing surfaces (F-12 viewer, F-13 PDF) and the stretch
claim-defensibility PDF (F-17). Off the critical path.

## Dependencies (must exist before this starts)

- **F-01 Walking skeleton** — needs the deployed Rails asset pipeline.

## Unblocks (what waits on this)

- **F-12 Web report viewer** — consumes the screen stylesheet and
  brand tokens.
- **F-13 PDF report** — consumes the print stylesheet and brand assets.
- **F-17 Claim-defensibility PDF** — extends F-13 with brand
  refinements that depend on F-04 tokens.

## Acceptance criteria

- **Wordmark + brand assets** in `app/assets/images/brand/`:
  - `rooftrace-wordmark.svg` — primary lockup, dark-on-light variant.
  - `rooftrace-wordmark-onorange.svg` — light-on-orange variant for
    the PDF header bar.
  - `rooftrace-icon.svg` — square mark for favicon / app icon
    placeholder.
  - A `brand/README.md` documenting palette, typography, and usage
    rules, with explicit "near-but-distinct from CompanyCam"
    framing.
- **Palette tokens** in `app/assets/stylesheets/brand/_tokens.scss`:
  - `$brand-orange` (~hi-viz construction-cone orange — exact hex
    documented; e.g. `#FF6A1F` as a starting point, verified
    visually against COMPANY.md guidance).
  - `$brand-charcoal` (body text), `$brand-white`, `$brand-gray-50`
    through `$brand-gray-900` for chrome and secondary text.
  - `$brand-confidence-high`, `$brand-confidence-medium`,
    `$brand-confidence-low` — muted grays per the
    honest-uncertainty UX, **not** stoplight red/yellow/green.
- **Typography tokens** in the same file:
  - Sans-serif system stack (Inter / SF Pro fallback); workmanlike,
    no quirky display fonts.
  - Type scale tokens for body, heading, monospace (used for
    measurements).
- **Shared `app/assets/stylesheets/report.scss`** consumed by:
  - A stub screen viewer page (`/reports/_demo` route or similar)
    that renders a placeholder roof diagram + measurements table
    using the brand tokens.
  - A stub PDF page using the same partial, with `@media print`
    rules at the bottom of the stylesheet adding page sizing,
    print-only sections (signature line, attribution footer), and
    page-break rules.
- **Print-only sections** (`.print-only`) are hidden on screen and
  visible in print; **screen-only sections** (`.screen-only`) are
  the inverse.
- **Color rule enforced visually:** orange appears only on the
  primary CTA + the PDF header bar — never as a decorative wash.
  Documented in `brand/README.md`.

## Testing requirements

- **Visual regression test:** the stub viewer page and stub PDF page
  rendered via the chosen test harness (Capybara screenshot for
  screen; Grover→PDF screenshot diff for print) — both compared
  against a committed golden image. Catches accidental brand
  drift.
- **Build smoke test:** the asset pipeline compiles `report.scss`
  without errors as part of CI.
- **Token-presence test:** asserts every documented brand token is
  defined and referenced at least once in `report.scss`.

## Manual setup required

- **Designer review of palette + wordmark** before merging — the
  brand contract is the design north star for every subsequent
  surface; getting this wrong cascades.
- **Verify visual against CompanyCam's actual site** (companycam.com)
  to confirm the "near-but-distinct" framing reads as deliberate
  rather than as appropriation. Adjust hex / wordmark proportions
  if needed.
- **Pick a hi-viz-orange hex value** that reads as construction-cone /
  PPE-adjacent in both screen and print (CMYK conversion matters for
  the PDF). Start with `#FF6A1F`; iterate visually.

## Implementation plan (approved 2026-05-28)

- [x] **C1 — Brand assets.** `app/assets/images/brand/`:
  `rooftrace-wordmark.svg` (dark-on-light), `rooftrace-wordmark-onorange.svg`,
  `rooftrace-icon.svg`, and `brand/README.md` (palette hex, typography,
  "near-but-distinct from CompanyCam" framing, orange-only-CTA rule).
- [x] **C2 — Brand tokens** as Tailwind v4 `@theme` custom properties (orange
  `#FF6A1F`, charcoal, white, gray-50..900, confidence-high/med/low as *muted
  grays*, type scale + monospace) in `app/assets/tailwind/brand.css`, imported by
  `application.css`.
- [x] **C3 — `app/assets/stylesheets/report.css`** (plain CSS, Propshaft-served):
  screen styles + `@media print` (page sizing, `.print-only`/`.screen-only`,
  page-breaks, print-only signature line + attribution footer). Orange only on
  primary CTA + PDF header bar.
- [x] **C4 — Stub pages.** `ReportsDemoController#show` at `/reports/_demo`
  rendering placeholder roof diagram + measurements table via the tokens; a
  print-target view reusing the same partial.
- [x] **C5 — Tests.** Token-presence test (every documented token defined +
  referenced in `report.css`), asset-compile smoke (Tailwind build + Propshaft
  compile clean), Capybara structural test of the stub page. Golden-image visual
  diff deferred to F-13 (Grover not yet installed) — noted.

## Implementation notes (filled in by the building agent)

> The agent implementing this feature records its implementation
> decisions and rationale here as it builds — chosen libraries/patterns
> within the architecture's constraints, trade-offs made, deviations
> from assumptions and why, and anything the next agent or the
> integrator needs to know. This section starts empty and is owned by
> the builder, not the planner. Cross-cutting discoveries that affect
> other features must also be propagated to ROADMAP.md or the
> architecture doc, not just left here.

- **SCSS → Tailwind v4 deviation (approved):** the app runs Tailwind CSS v4 +
  Propshaft with no SCSS pipeline. The spec named `_tokens.scss` / `report.scss`.
  Per ADR-013 (Hotwire stack) and to avoid a second CSS toolchain, brand tokens
  are Tailwind v4 `@theme` custom properties and `report.css` is plain CSS with
  `@media print`. The COMPANY.md brand *contract* stays fully binding; only the
  file format changed.
- **Visual-regression golden image deferred:** Grover (headless-Chrome PDF) is
  not installed until F-13. Pixel golden-diff deferred to F-13; this feature
  ships deterministic token-presence + asset-compile + Capybara structural tests.

### C4 server-boot verification (2026-05-28)

Booted `bin/rails server -p 3009 RAILS_ENV=test` with PostGIS container at port 5433.

```
HTTP status: 200
Grep: confidence Confidence rooftrace RoofTrace sq ft
```

Command: `curl -sS -o /dev/null -w "%{http_code}\n" http://localhost:3009/reports/_demo` → **200**
Command: `curl -sS http://localhost:3009/reports/_demo | grep -oiE "RoofTrace|confidence|sq ft"` → **RoofTrace, confidence, sq ft** all present.

### C5 test results (2026-05-28)

```
bundle exec rspec spec/assets/brand_tokens_spec.rb spec/requests/reports_demo_spec.rb
73 examples, 0 failures
```

Tailwind build smoke: `bin/rails tailwindcss:build` → `Done in 45ms` (exit 0).
RuboCop: 4 files inspected, no offenses detected.
