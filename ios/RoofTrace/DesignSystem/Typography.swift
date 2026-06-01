import SwiftUI

extension Font {
    enum RoofTrace {
        static let display = Font.custom("Archivo-ExtraBold", size: 44, relativeTo: .largeTitle)
        static let title = Font.custom("Archivo-ExtraBold", size: 30, relativeTo: .title)
        static let headline = Font.custom("Inter-SemiBold", size: 18, relativeTo: .headline)
        static let body = Font.custom("Inter-Regular", size: 16, relativeTo: .body)
        static let bodyMedium = Font.custom("Inter-Medium", size: 16, relativeTo: .body)
        static let label = Font.custom("Inter-SemiBold", size: 13, relativeTo: .caption)
        static let button = Font.custom("Inter-SemiBold", size: 16, relativeTo: .body)
        static let monoXL = Font.system(size: 32, weight: .semibold, design: .monospaced)
    }
}
