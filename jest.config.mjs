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
