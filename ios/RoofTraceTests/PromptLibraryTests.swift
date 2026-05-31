import XCTest
@testable import RoofTrace

/// Coverage for `PromptLibrary.step(at:)`, which now returns `PromptStep?`.
/// Guards step count, in-bounds/out-of-bounds behavior, and the
/// `steps.count == CaptureSessionState.promptCount` invariant that the
/// walk-around capture sequence depends on.
final class PromptLibraryTests: XCTestCase {

    func testFirstStepLabelIsFrontLeftCorner() {
        XCTAssertEqual(PromptLibrary.step(at: 0)?.label, .frontLeftCorner)
    }

    func testLastStepLabelIsLeftFacade() {
        // Index 7 is the eighth and final step.
        XCTAssertEqual(PromptLibrary.step(at: 7)?.label, .leftFacade)
    }

    func testStepBeyondBoundsReturnsNil() {
        XCTAssertNil(PromptLibrary.step(at: 8),
                     "index 8 is one past the end; must return nil")
    }

    func testNegativeIndexReturnsNil() {
        XCTAssertNil(PromptLibrary.step(at: -1),
                     "negative index must return nil")
    }

    /// `PromptLibrary.steps.count` must equal `CaptureSessionState.promptCount`
    /// so the capture loop terminates exactly when the library is exhausted.
    func testStepCountMatchesPromptCount() {
        XCTAssertEqual(PromptLibrary.steps.count, CaptureSessionState.promptCount)
    }

    /// Each step's `captureIndex` must equal its position in the array, so the
    /// view model's index-based dispatch (`PromptLibrary.step(at: index)`) is
    /// stable and there are no gaps.
    func testCaptureIndicesAreContiguousFromZero() {
        for (position, step) in PromptLibrary.steps.enumerated() {
            XCTAssertEqual(step.captureIndex, position,
                           "step at position \(position) has captureIndex \(step.captureIndex)")
        }
    }

    /// Every step's label is unique (no duplicate prompts).
    func testAllStepLabelsAreDistinct() {
        let labels = PromptLibrary.steps.map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count, "all prompt labels must be distinct")
    }
}
