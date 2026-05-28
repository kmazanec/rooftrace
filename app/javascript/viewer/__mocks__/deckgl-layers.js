// Manual mock for @deck.gl/layers (see jest.config.mjs moduleNameMapper).
// The real package transitively loads @loaders.gl / @luma.gl / wgsl_reflect that
// jest's ESM runtime cannot transform. The layer builders are exercised
// structurally elsewhere, so stub the layer classes the component imports.
// Authored as ESM named exports (package.json "type":"module") so the
// component's `import { PolygonLayer } from "@deck.gl/layers"` resolves.
export class PolygonLayer {}
export class ScatterplotLayer {}
export class TextLayer {}
