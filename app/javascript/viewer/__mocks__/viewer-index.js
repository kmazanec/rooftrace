// Manual mock for ./index (mountRoofViewer), wired via jest.config.mjs
// moduleNameMapper (the same strategy as the deck.gl/maplibre mocks — in-spec
// jest.mock factories are NOT hoisted above static imports under ts-jest ESM, so
// the real React/WebGL graph would load otherwise). The bootstrap test only
// needs to know that mounting was invoked, so this records calls instead of
// rendering. `__calls` is read back by the spec through the mapped module.
// Authored as ESM (package.json "type":"module") to match the real ./index.
export const __calls = [];

export function mountRoofViewer(...args) {
  __calls.push(args);
  return { unmount() {}, render() {} };
}

export default mountRoofViewer;
