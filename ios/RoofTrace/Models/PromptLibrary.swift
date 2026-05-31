import Foundation

/// One guided walk-around step. `label` is the frozen `prompt_label` enum value
/// written into session.json; `bearingDegrees` is the compass heading the user
/// should roughly face (0 = north, 90 = east), used by the compass-needle hint.
struct PromptStep: Identifiable, Equatable {
    var id: Int { captureIndex }
    let captureIndex: Int
    let label: PromptLabel
    let title: String
    let instruction: String
    /// Compass bearing hint, degrees clockwise from north.
    let bearingDegrees: Double
    /// SF Symbol name for the illustration.
    let symbolName: String
}

/// The fixed 8-step library, in capture order. The order matches
/// `PromptLabel.allCases` and the synthetic fixture's capture sequence.
enum PromptLibrary {
    static let steps: [PromptStep] = [
        PromptStep(captureIndex: 0, label: .frontLeftCorner,
                   title: "Front-left corner",
                   instruction: "Stand at the front-left corner of the house. Frame the corner where the front and left walls meet, including the roof edge.",
                   bearingDegrees: 45, symbolName: "arrow.up.left.square"),
        PromptStep(captureIndex: 1, label: .frontFacade,
                   title: "Front facade",
                   instruction: "Step back and center the entire front of the house. Keep the full roofline in frame.",
                   bearingDegrees: 0, symbolName: "house"),
        PromptStep(captureIndex: 2, label: .frontRightCorner,
                   title: "Front-right corner",
                   instruction: "Move to the front-right corner. Frame where the front and right walls meet, with the roof edge visible.",
                   bearingDegrees: 315, symbolName: "arrow.up.right.square"),
        PromptStep(captureIndex: 3, label: .rightFacade,
                   title: "Right facade",
                   instruction: "Center the right side of the house. Capture the full side roofline.",
                   bearingDegrees: 270, symbolName: "house"),
        PromptStep(captureIndex: 4, label: .backRightCorner,
                   title: "Back-right corner",
                   instruction: "Move to the back-right corner. Frame the corner and roof edge.",
                   bearingDegrees: 225, symbolName: "arrow.down.right.square"),
        PromptStep(captureIndex: 5, label: .backFacade,
                   title: "Back facade",
                   instruction: "Center the back of the house. Keep the full rear roofline in frame.",
                   bearingDegrees: 180, symbolName: "house"),
        PromptStep(captureIndex: 6, label: .backLeftCorner,
                   title: "Back-left corner",
                   instruction: "Move to the back-left corner. Frame the corner and roof edge.",
                   bearingDegrees: 135, symbolName: "arrow.down.left.square"),
        PromptStep(captureIndex: 7, label: .leftFacade,
                   title: "Left facade",
                   instruction: "Center the left side of the house. Capture the full side roofline.",
                   bearingDegrees: 90, symbolName: "house"),
    ]

    static func step(at index: Int) -> PromptStep? {
        steps.indices.contains(index) ? steps[index] : nil
    }
}
