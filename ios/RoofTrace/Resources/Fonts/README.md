# Bundled fonts (ADR-020)

OFL-licensed static instances, generated 2026-05-31 from the Google Fonts variable
sources (`Inter[opsz,wght]`, `Archivo[wdth,wght]`) via `fonttools varLib.instancer`,
with the name/OS-2 weight records rewritten so each file has a unique PostScript name.
Licenses: `OFL-Inter.txt`, `OFL-Archivo.txt` (redistribution permitted).

`UIFont`/SwiftUI load by **PostScript name** (not filename). Wire these into the
Info.plist `UIAppFonts` array (filenames) and reference the PostScript names in the
`Font` scale:

| File (UIAppFonts entry)   | PostScript name      | Weight | Use (ADR-020)                    |
|---------------------------|----------------------|--------|----------------------------------|
| `Archivo-ExtraBold.ttf`   | `Archivo-ExtraBold`  | 800    | Display tier ONLY (login hero, headlines) |
| `Inter-Regular.ttf`       | `Inter-Regular`      | 400    | Body                             |
| `Inter-Medium.ttf`        | `Inter-Medium`       | 500    | Body emphasis / labels           |
| `Inter-SemiBold.ttf`      | `Inter-SemiBold`     | 600    | Buttons / section labels         |
| `Inter-Bold.ttf`          | `Inter-Bold`         | 700    | Strong emphasis                  |

Measurements use the **system monospaced** face (SF Mono / Menlo) — NOT bundled.

`AppIcon.svg` (sibling dir) is the editable source for `Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`;
re-render with `rsvg-convert -w 1024 -h 1024 AppIcon.svg -o ...AppIcon-1024.png` then
`sips --setProperty hasAlpha no` (App Store icons must be opaque).
