import XCTest
@testable import RoofTrace

/// Phase 2.6 — the capture session state machine. Written before implementation.
final class CaptureSessionStateTests: XCTestCase {

    func testForwardHappyPath() {
        var s = CaptureSessionState.tokenEntry
        XCTAssertTrue(s.advance(to: .setupCheck))
        XCTAssertTrue(s.advance(to: .capturePrompt(0)))
        for i in 0..<7 {
            XCTAssertTrue(s.advance(to: .capturePrompt(i + 1)), "prompt \(i) -> \(i+1)")
        }
        // After the 8th capture (index 7), the next step is uploading.
        XCTAssertTrue(s.advance(to: .uploading))
        XCTAssertTrue(s.advance(to: .uploadComplete))
    }

    func testCapturePromptEightIsUnreachable() {
        var s = CaptureSessionState.capturePrompt(7)
        // There is no prompt index 8 — only 0...7. From 7, uploading is next.
        XCTAssertFalse(s.advance(to: .capturePrompt(8)))
        XCTAssertTrue(CaptureSessionState.isValidPromptIndex(7))
        XCTAssertFalse(CaptureSessionState.isValidPromptIndex(8))
        XCTAssertFalse(CaptureSessionState.isValidPromptIndex(-1))
    }

    func testSetupCheckToLidarUnsupported() {
        var s = CaptureSessionState.setupCheck
        XCTAssertTrue(s.advance(to: .lidarUnsupported))
    }

    func testTerminalStatesHaveNoTransitions() {
        for terminal in [CaptureSessionState.uploadComplete,
                         .bundleSaved,
                         .lidarUnsupported] {
            XCTAssertTrue(terminal.isTerminal, "\(terminal) should be terminal")
            var s = terminal
            XCTAssertFalse(s.advance(to: .uploading), "\(terminal) must not advance")
            XCTAssertFalse(s.advance(to: .tokenEntry))
        }
    }

    func testRetryPath() {
        var s = CaptureSessionState.uploading
        XCTAssertTrue(s.advance(to: .uploadFailed))
        // Retry: failed -> uploading -> complete.
        XCTAssertTrue(s.advance(to: .uploading))
        XCTAssertTrue(s.advance(to: .uploadComplete))
    }

    func testSavePath() {
        var s = CaptureSessionState.uploadFailed
        XCTAssertTrue(s.advance(to: .bundleSaved))
        XCTAssertTrue(s.isTerminal)
    }

    func testCannotSkipSetupCheck() {
        var s = CaptureSessionState.tokenEntry
        XCTAssertFalse(s.advance(to: .capturePrompt(0)))
        XCTAssertFalse(s.advance(to: .uploading))
    }

    func testNonSequentialPromptRejected() {
        var s = CaptureSessionState.capturePrompt(2)
        XCTAssertFalse(s.advance(to: .capturePrompt(5)))
        XCTAssertFalse(s.advance(to: .capturePrompt(2)))
    }
}
