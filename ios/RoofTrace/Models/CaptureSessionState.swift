import Foundation

/// The capture-flow state machine. Drives which view `RoofTraceApp` shows.
///
/// Flow:
///   tokenEntry -> setupCheck -> capturePrompt(0) -> ... -> capturePrompt(7)
///     -> uploading -> uploadComplete (terminal)
///   setupCheck -> lidarUnsupported (terminal, non-Pro device)
///   uploading -> uploadFailed -> uploading (retry) | bundleSaved (terminal)
///
/// There are exactly 8 capture prompts, indices 0...7. `capturePrompt(8)` is
/// unreachable — after index 7 the only forward transition is `uploading`.
enum CaptureSessionState: Equatable {
    case tokenEntry
    case setupCheck
    case capturePrompt(Int)   // 0...7
    case uploading
    case uploadComplete       // terminal
    case uploadFailed
    case bundleSaved          // terminal
    case lidarUnsupported     // terminal

    /// Number of guided prompts (4 corners + 4 facades).
    static let promptCount = 8

    static func isValidPromptIndex(_ i: Int) -> Bool {
        (0..<promptCount).contains(i)
    }

    var isTerminal: Bool {
        switch self {
        case .uploadComplete, .bundleSaved, .lidarUnsupported:
            return true
        default:
            return false
        }
    }

    /// True iff `next` is a legal transition from `self`. Terminal states allow none.
    func canTransition(to next: CaptureSessionState) -> Bool {
        switch (self, next) {
        case (.tokenEntry, .setupCheck):
            return true
        case (.setupCheck, .capturePrompt(0)):
            return true
        case (.setupCheck, .lidarUnsupported):
            return true
        case let (.capturePrompt(from), .capturePrompt(to)):
            // Strictly sequential, within range.
            return Self.isValidPromptIndex(from)
                && Self.isValidPromptIndex(to)
                && to == from + 1
        case (.capturePrompt(let i), .uploading):
            // Only after the last prompt (index 7).
            return i == Self.promptCount - 1
        case (.uploading, .uploadComplete):
            return true
        case (.uploading, .uploadFailed):
            return true
        case (.uploadFailed, .uploading):   // retry
            return true
        case (.uploadFailed, .bundleSaved): // save locally
            return true
        default:
            return false
        }
    }

    /// Attempts the transition, mutating in place. Returns false (no mutation) if illegal.
    @discardableResult
    mutating func advance(to next: CaptureSessionState) -> Bool {
        guard canTransition(to: next) else { return false }
        self = next
        return true
    }
}
