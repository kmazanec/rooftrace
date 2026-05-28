// Manual mock for @deck.gl/react (see jest.config.mjs moduleNameMapper).
// The real package pulls in @luma.gl / wgsl_reflect, which jest's ESM runtime
// cannot evaluate. The unit tests only assert the component's React structure,
// so a placeholder canvas element is enough. Authored as an ESM default export
// (package.json "type":"module") to match `import DeckGL from "@deck.gl/react"`.
import React from "react";

const DeckGL = () => React.createElement("div", { "data-testid": "deckgl-canvas" });

export default DeckGL;
