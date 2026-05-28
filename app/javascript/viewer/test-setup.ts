import "@testing-library/jest-dom";

// jsdom does not implement URL.createObjectURL / revokeObjectURL. maplibre-gl
// evaluates these at module-import time (worker bootstrap), so even though the
// component tests jest.mock("maplibre-gl"), ts-jest's ESM hoisting still lets
// the real dist bundle's top-level side-effects run and blow up with
// "window.URL.createObjectURL is not a function" before the mock takes hold.
// Polyfill them as no-ops so the module graph loads GPU-free.
if (typeof window.URL.createObjectURL !== "function") {
  window.URL.createObjectURL = () => "";
}
if (typeof window.URL.revokeObjectURL !== "function") {
  window.URL.revokeObjectURL = () => {};
}
