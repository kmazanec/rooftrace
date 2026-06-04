// Manual mock for @deck.gl/layers (see jest.config.mjs moduleNameMapper).
// The real package transitively loads @loaders.gl / @luma.gl / wgsl_reflect that
// jest's ESM runtime cannot transform. The layer builders are exercised
// structurally elsewhere, so stub the layer classes the component imports.
// Authored as ESM named exports (package.json "type":"module") so the
// component's `import { PolygonLayer } from "@deck.gl/layers"` resolves.
//
// The stubs retain the constructor props on `.props` so buildLayers unit tests
// can assert the layer configuration (extrusion, elevation accessors, 3D point
// positions) without a GPU.
class MockLayer {
  constructor(props) {
    this.props = props;
    this.id = props && props.id;
  }
}
export class PolygonLayer extends MockLayer {}
export class ScatterplotLayer extends MockLayer {}
export class TextLayer extends MockLayer {}
