# ADR-020: Native iOS design system honors the web two-palette system; ship light-only in v1

**Status:** Accepted · **Date:** 2026-05-31 · **Stretch:** no
**Supersedes:** none · **Superseded by:** none

## Context

The full-featured iOS app (ADR-007 amendment) introduces real product surfaces —
login, a job-list home, address entry, live status, the relocated capture flow, and
a native report viewer. The current capture-only app ships **raw SwiftUI defaults**:
system `.tint` blue, stoplight `.green`/`.red`, `.title2.bold()`, `.borderedProminent`.
That is correct but **voiceless**, and it contradicts the brand the app belongs to.

The web has a deliberate, disciplined **two-palette** system that we must honor
rather than reinvent:

- **`cc-*` (CompanyCam's real brand)** for **entry surfaces** (login, new-job,
  status): CC Blue `#0967D2` as the primary action; CC Orange `#FF4B00` as an
  accent only (eyebrows, rules, completed checks); CC Ink `#142334` text on a
  warm-white CC Chalk `#F7F6F2` background; CC Line `#E7E8EA` borders.
- **`brand-*` (sober "construction-document authority")** for the **report
  surface** (and PDF): Brand Orange `#FF6A1F` on report CTAs **only**; Brand
  Charcoal `#1C1C1E` text on white; a full gray ramp; and confidence shown in
  **muted grays** (high `#374151`, med `#6B7280`, low `#9CA3AF`) — never a
  red/green stoplight, both for colorblind accessibility and the instrument feel.

Type: body/UI is **Inter** (web) / SF Pro; display headlines are **Archivo
ExtraBold**, uppercase, tight tracking; **all measurements are monospace** (the
"instrument reading" aesthetic). The memory note "two-palette brand system —
don't cross them" is the rule this ADR encodes into the type system.

The advisory design pass (Scher / Refactoring-UI / Frost) also raised a
field-use decision: roofers use this **outdoors, in bright sun, often one-handed
on a ladder**. That bears directly on whether to support dark mode.

## Decision

**A native design system that mirrors the web two-palette split, plus a deliberate
LIGHT-ONLY v1.**

1. **Asset-catalog semantic color sets, namespaced by palette.** Every token is an
   Xcode asset-catalog Color Set exposed through Swift so views never touch raw
   hex: `Color.CC.*` for the entry palette (`blue`, `blueHover`, `orange`,
   `orangeHigh`, `ink`, `ink75`, `ink55`, `chalk`, `surface`, `line`, `lineMid`)
   and `Color.Brand.*` for the report palette (`orange`, `charcoal`, `white`, the
   `gray50…gray900` ramp, `confidenceHigh/Medium/Low`). The exact hex values are
   those listed in Context above (sourced from `app/assets/stylesheets/cc.css` and
   `app/assets/tailwind/brand.css`). **The two namespaces must never cross:** a
   `Brand.*`/`Confidence*` color may not appear on an entry surface and a `CC.*`
   color may not appear in the report viewer. Where practical this is enforced by
   the component API (report components take only `Brand`-namespaced styling), not
   just by convention.

2. **Bundle Archivo ExtraBold (display only) + Inter (body); SF Mono for all
   measurements.** Archivo and Inter are bundled (OFL, a few hundred KB) via
   `UIAppFonts` so the app reads as RoofTrace, not as the default Apple voice —
   substituting SF Pro for the Archivo display tier is the exact "AI-default"
   look we are escaping. Measurements use the **system monospaced** face (SF Mono
   / Menlo) — no bundling needed. A single `Font` scale maps the web scale
   (XL 24 / LG 20 / MD 16 / body 14 / sm 12; mono 16/14/12) with two field-driven
   deviations: **body is 16 pt** (not 14 — arm's-length legibility in glare) and a
   new **`monoXL` (~32 pt)** tier for the one hero number a roofer quotes (total
   roof area), used on the job-list featured card and the report stat strip. The
   scale uses Dynamic Type via `relativeTo:`; display tiers cap at
   `.accessibility2` so the Archivo composition doesn't shatter, while body / mono
   / labels scale freely (measurements wrap rather than truncate).

3. **A ~14-component kit, built once** (Frost lens), all token-driven, in a
   `Components/` group: `EyebrowLabel`, `ScreenHeader`, `SectionHeader`,
   `PrimaryButton` (and a report-only orange variant in a separate namespace),
   `GhostButton`, `Card`, `JobRow`, `StatusIndicator` (the multi-status pill),
   `StatProbe` (label + `MonoValue`), `ConfidenceChip`, `FacetSwatch`,
   `ProgressDots`/`SegmentedProgress`, `CompassCard`, plus `InlineErrorBlock` and
   an `EmptyStateView`. No screen invents a second button style; nothing uses
   `.borderedProminent` again.

4. **Ship light-only in v1.** Lock the interface to light (`UIUserInterfaceStyle
   = Light` / `.preferredColorScheme(.light)`). This is a deliberate decision, not
   an omission: the brand is a **warm-white / paper-document identity** (chalk
   entry surfaces, white report surfaces, navy/charcoal ink), and an auto dark
   mode would invert the report into something that reads as a *screen* rather
   than a *filed document*, breaking the authority that makes contractors trust
   the numbers. Outdoor sunlight legibility is **better** served by a
   high-brightness light UI with dark ink than by a dark UI (which washes out and
   mirrors in direct sun). If dark mode is ever wanted it must be a separately
   art-directed theme, never an auto-inversion.

## Rationale

Honoring the web palettes verbatim keeps one brand across web, PDF, and app, and
encodes the "don't cross the palettes" rule structurally. Bundling the display +
body faces is what makes the app feel *designed* rather than defaulted — the cheap,
high-leverage move. Light-only removes a whole class of dark-mode contrast bugs in
a constrained build, and is the *correct* call for the document identity and the
field, not merely the expedient one — which is exactly why it belongs in an ADR
where a future contributor will see the reasoning before "helpfully" adding dark
mode.

## Tradeoffs & risks

- **No dark mode.** Mitigation: documented as a deliberate v1 stance with a real
  rationale; revisit only with a purpose-built dark theme.
- **CC Orange `#FF4B00` fails WCAG AA for body-size text on chalk (~3.4:1).**
  Mitigation: orange is for **large display accents, rules, glyphs, and the
  eyebrow only** — never body-size running text (this matches the web's own use).
  ConfidenceLow `#9CA3AF` likewise fails as small text, so the confidence chip
  always pairs the gray dot with the **word** in a darker gray and a shape cue (a
  bar/▲ glyph) — meaning never rides on color alone.
- **Bundled fonts add app size.** Mitigation: Archivo+Inter are small; Inter could
  fall back to SF Pro if size ever matters, but Archivo is kept (it carries the
  identity).
- **Asset-catalog token sprawl.** Mitigation: one Swift file fronts every token;
  views import the namespaced `Color.CC.*` / `Color.Brand.*` only.

## Consequences for the build

- A `DesignSystem/` (colors + fonts + modifiers) and `Components/` group land in
  the iOS foundation feature as the **login screen's first consumer**, then extend
  per screen (mirroring how the web's brand assets feature seeded the stylesheet).
  This is **not** a standalone "build the components" feature — it ships inside the
  first screen that uses it (vertical-slice discipline).
- Fonts registered via `UIAppFonts`; color sets added to the asset catalog; both
  must be added to the (now glob-based) `gen_pbxproj.py` discovery.
- App identity artifacts decided here: the **roof-peak glyph app icon** (navy +
  warm-white + one orange ridge stroke — flat, document-like, not a gradient
  "AI-default" icon), a **chalk launch screen** (glyph + Archivo wordmark + an
  orange rule), and two signature typographic moments — the **login Archivo
  hero** and the **giant mono area number** on the report and job-list hero.
- Accessibility floor: tap targets ≥ 44 pt (primary buttons 54–60 pt for gloved
  one-handed use); the report tables are the VoiceOver source of truth for
  measurements (combined accessibility elements, not per-cell reads); all
  state-change animations honor `accessibilityReduceMotion`.
