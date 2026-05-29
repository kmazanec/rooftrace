# RoofTrace Brand Assets

## Near-but-distinct from CompanyCam

RoofTrace is a companion product built for CompanyCam's contractor audience.
Its visual language riffs deliberately on CompanyCam's hi-viz-orange / monochrome
aesthetic — the intent is that a CompanyCam user sees RoofTrace and immediately
recognizes the visual family. However, RoofTrace does **not** use CompanyCam's
wordmark, logotype, or exact brand assets. The peak-glyph icon and "RoofTrace"
wordmark are original.

CompanyCam's palette: saturated hi-viz orange + monochrome. Our palette follows
the same structure (one action color + neutral grays + charcoal/white body) but
uses our own hex values verified against WCAG contrast requirements. We treat
this as a "RoofTrace by CompanyCam" family relationship, not a copy.

---

## Two palettes

RoofTrace ships **two coordinated palettes**, chosen per surface:

1. **Report palette** (below) — the PDF and the report viewer. A sober,
   filed-ready construction document: orange stays disciplined to the CTA +
   header bar, ink is charcoal `#1C1C1E`, surfaces are pure white, grays are
   cool. This is the original palette; it is unchanged.

2. **Contractor-surface palette** (`--color-cc-*`, see the table at the end of
   this file) — the login, new-job, and status screens. These match
   CompanyCam's **real shipping brand** (pulled from their production CSS):
   traffic-cone orange `#FF4B00` as the brand identity color, blue `#0967D2`
   as the primary action, navy-charcoal `#142334` ink, warm-white `#F7F6F2`
   surfaces. On these screens **blue is the primary button** and **orange is a
   brand/accent color** (panels, rules, the completed-stage check) — mirroring
   how CompanyCam itself uses color. Display headers are heavy uppercase
   Archivo (a free substitute for CompanyCam's Roc Grotesk).

The split is deliberate: the entry flow should feel like a native CompanyCam
product, while the deliverable PDF should read like a sober insurance/
construction document. Tokens for both live in `app/assets/tailwind/brand.css`.

## Report palette

| Token                  | Hex       | Usage                                              |
|------------------------|-----------|----------------------------------------------------|
| Brand orange           | `#FF6A1F` | Report CTA buttons, PDF header bar ONLY            |
| Brand charcoal         | `#1C1C1E` | Body text, headings, UI chrome, icon strokes       |
| Brand white            | `#FFFFFF` | Page surfaces, card backgrounds                    |
| Gray 50                | `#F9FAFB` | Alternate row backgrounds, subtle fills            |
| Gray 100               | `#F3F4F6` | Card borders, dividers                             |
| Gray 200               | `#E5E7EB` | Secondary borders                                  |
| Gray 300               | `#D1D5DB` | Placeholder text borders                           |
| Gray 400               | `#9CA3AF` | Disabled text, secondary labels                    |
| Gray 500               | `#6B7280` | Muted body copy, footnotes                         |
| Gray 600               | `#4B5563` | Secondary headings                                 |
| Gray 700               | `#374151` | Data labels                                        |
| Gray 800               | `#1F2937` | Near-charcoal body copy                            |
| Gray 900               | `#111827` | Maximum contrast (accessible alternative)          |
| Confidence high        | `#374151` | Measurement with high confidence (dark gray)       |
| Confidence medium      | `#6B7280` | Measurement with medium confidence (mid gray)      |
| Confidence low         | `#9CA3AF` | Measurement with low confidence (light gray)       |

**Critical rule (report palette only):** `#FF6A1F` appears **only** on the
report CTA and the PDF header bar — never as a decorative wash, fill, chart
accent, or secondary element on the report/PDF. This keeps the construction-
document authority of the deliverable. (The contractor-surface palette below
follows CompanyCam's own conventions instead — blue primary, orange as a brand
accent — and does not inherit this restriction.)

## Contractor-surface palette (`--color-cc-*`)

Login / new-job / status. Matches CompanyCam's real shipping brand.

| Token                | Hex / value              | Usage                                         |
|----------------------|--------------------------|-----------------------------------------------|
| `--color-cc-orange`  | `#FF4B00`                | Brand accent: eyebrows, rules, stage check    |
| `--color-cc-orange-high` | `#FF8500`            | Brighter hi-vis accent                        |
| `--color-cc-blue`    | `#0967D2`                | **Primary action button** (the workhorse CTA) |
| `--color-cc-blue-hover` | `#2276D6`             | Primary button hover                          |
| `--color-cc-yellow`  | `#FFD000`                | High-emphasis secondary CTA (reserved)        |
| `--color-cc-ink`     | `#142334`                | Headings + body ink (navy-charcoal)           |
| `--color-cc-ink-75`  | `rgba(20,35,52,.75)`     | Body copy                                     |
| `--color-cc-ink-55`  | `rgba(20,35,52,.55)`     | Muted / secondary copy                        |
| `--color-cc-chalk`   | `#F7F6F2`                | Warm-white page background                    |
| `--color-cc-line`    | `#E7E8EA`                | Borders, dividers, field outlines             |
| `--color-cc-line-mid`| `#B8BCC1`                | Placeholder text, stronger lines              |

Display font: `--font-display` → **Archivo** (heavy, UPPERCASE), with Inter as
the body/UI face. Both are loaded from Google Fonts in the app + auth layouts.
Component styles live in `app/assets/stylesheets/cc.css`.

---

## Typography

### Typefaces

- **Body + UI:** `'Inter', 'SF Pro Display', system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif`
  Clean, geometric, high legibility at screen and print sizes. Workmanlike, not
  quirky. This is the same category of typeface CompanyCam uses.

- **Measurements (monospace):** `'SF Mono', 'Fira Code', 'Fira Mono', 'Roboto Mono', ui-monospace, monospace`
  Measurement values (sq ft, pitch, run/rise) are rendered in a monospace face
  for tabular alignment and to reinforce the "instrument reading" aesthetic.

### Type scale

| Token          | Size   | Usage                                |
|----------------|--------|--------------------------------------|
| Heading XL     | 1.5rem | Report title, page section headers   |
| Heading LG     | 1.25rem| Card headings, subsection headers    |
| Heading MD     | 1rem   | Column labels, card subtitles        |
| Body           | 0.875rem| Standard body copy (14px)           |
| Body SM        | 0.75rem | Secondary copy, footnotes (12px)    |
| Mono LG        | 1rem   | Primary measurement values           |
| Mono MD        | 0.875rem| Secondary measurement values        |
| Mono SM        | 0.75rem | Table cells, compact measurements   |

---

## Asset files

| File                                | Variant             | Background      |
|-------------------------------------|---------------------|-----------------|
| `rooftrace-wordmark.svg`            | Primary wordmark    | Transparent     |
| `rooftrace-wordmark-onorange.svg`   | Header bar lockup   | `#FF6A1F` fill  |
| `rooftrace-icon.svg`                | Square mark / icon  | Transparent     |
| `rooftop-hero.jpg`                  | Login panel photo   | Photographic    |

`rooftop-hero.jpg` is a free-license (Unsplash) residential-rooftop photo used
behind the navy/orange wash on the login split-screen (`.cc-auth__panel`).
Swap freely for a real CompanyCam jobsite photo — keep it a roof-forward,
documentary image (not glossy stock) to match the brand's photography ethos.
On the panel the dark wordmark is inverted to white via CSS `filter`.

### Usage rules

- Use `rooftrace-wordmark.svg` on white or light-gray backgrounds.
- Use `rooftrace-wordmark-onorange.svg` only inside the PDF header bar or an
  orange-filled nav element. The orange background is part of the SVG — do not
  place the dark-wordmark variant on an orange background.
- Do not recolor, stretch, or add drop shadows to the wordmark.
- Minimum display width for the wordmark: 120px. Below that, use
  `rooftrace-icon.svg` only.
