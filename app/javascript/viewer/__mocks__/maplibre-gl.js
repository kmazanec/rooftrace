// Manual mock for maplibre-gl (see jest.config.mjs moduleNameMapper).
// The real dist bundle runs WebGL/worker bootstrap at import time, which jsdom
// cannot satisfy. The unit tests only need the Map constructor surface the
// component calls (jumpTo / remove). Authored as an ESM named export
// (package.json "type":"module") to match `import { Map } from "maplibre-gl"`.
export class Map {
  jumpTo() {}
  remove() {}
}
