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

## Palette

| Token                  | Hex       | Usage                                              |
|------------------------|-----------|----------------------------------------------------|
| Brand orange           | `#FF6A1F` | Primary CTA buttons, PDF header bar ONLY           |
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

**Critical rule:** `#FF6A1F` (brand orange) appears **only** on:
1. The single primary CTA element on a screen (e.g. "Download Report" button).
2. The PDF header bar containing the wordmark.

Orange is **never** used as a decorative wash, background fill, chart accent,
or secondary element. Violating this dilutes the construction-document authority
that makes the brand distinctive.

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

### Usage rules

- Use `rooftrace-wordmark.svg` on white or light-gray backgrounds.
- Use `rooftrace-wordmark-onorange.svg` only inside the PDF header bar or an
  orange-filled nav element. The orange background is part of the SVG — do not
  place the dark-wordmark variant on an orange background.
- Do not recolor, stretch, or add drop shadows to the wordmark.
- Minimum display width for the wordmark: 120px. Below that, use
  `rooftrace-icon.svg` only.
