// Jest config for the React viewer-island unit tests (pure TS logic +
// light RTL). WebGL/map layers are NOT exercised here — only GPU-free units
// (colorByPitch, confidenceLabel) and the mount/affordance behavior.
export default {
  preset: "ts-jest/presets/default-esm",
  testEnvironment: "jsdom",
  extensionsToTreatAsEsm: [".ts", ".tsx"],
  roots: ["<rootDir>/app/javascript"],
  testMatch: ["**/*.test.ts", "**/*.test.tsx"],
  setupFilesAfterEnv: ["<rootDir>/app/javascript/viewer/test-setup.ts"],
  moduleNameMapper: {
    // CSS imports (e.g. maplibre-gl/dist/maplibre-gl.css) carry no behavior the
    // unit tests care about and ts-jest can't transform them. Stub every .css
    // import to an empty module so the component graph loads without choking on
    // the real stylesheet. The maplibre-gl.css file physically exists, so a
    // jest.mock(..., {virtual:true}) in the spec is insufficient.
    "\\.css$": "<rootDir>/app/javascript/viewer/__mocks__/styleMock.js",
    // The map/WebGL stack (maplibre-gl, @deck.gl/react, @deck.gl/layers) runs
    // GPU/worker bootstrap and pulls in @luma.gl / @loaders.gl / wgsl_reflect at
    // import time — none of which jest's ESM runtime can evaluate under jsdom.
    // Map them to lightweight manual mocks here rather than via in-spec
    // jest.mock(), because jest.mock factories are NOT reliably hoisted above
    // static imports under ts-jest ESM, so the real module graph would still
    // load and crash the suite before any test runs.
    "^@deck\\.gl/react$": "<rootDir>/app/javascript/viewer/__mocks__/deckgl-react.js",
    "^@deck\\.gl/layers$": "<rootDir>/app/javascript/viewer/__mocks__/deckgl-layers.js",
    "^maplibre-gl$": "<rootDir>/app/javascript/viewer/__mocks__/maplibre-gl.js",
    "^(\\.{1,2}/.*)\\.js$": "$1",
  },
  transform: {
    "^.+\\.tsx?$": [
      "ts-jest",
      {
        useESM: true,
        tsconfig: {
          jsx: "react-jsx",
          esModuleInterop: true,
          allowImportingTsExtensions: true,
          verbatimModuleSyntax: false,
          types: ["jest", "node", "@testing-library/jest-dom"],
        },
      },
    ],
  },
};
