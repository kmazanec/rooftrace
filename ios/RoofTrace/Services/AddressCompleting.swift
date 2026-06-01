import Foundation
import MapKit

struct AddressSuggestion: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String

    var displayAddress: String {
        [title, subtitle]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

enum TypeaheadState: Equatable, Sendable {
    case tooShort
    case searching
    case results([AddressSuggestion])
    case noMatches
}

protocol AddressCompleting: Sendable {
    func suggestions(for query: String) async throws -> [AddressSuggestion]
}

@MainActor
final class MapKitAddressCompleter: NSObject, AddressCompleting, MKLocalSearchCompleterDelegate {
    private let completer = MKLocalSearchCompleter()
    private var continuation: CheckedContinuation<[AddressSuggestion], Error>?

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = .address
    }

    func suggestions(for query: String) async throws -> [AddressSuggestion] {
        continuation?.resume(returning: [])
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            completer.queryFragment = query
        }
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        Task { @MainActor in
            let suggestions = completer.results.map {
                AddressSuggestion(
                    id: "\($0.title)|\($0.subtitle)",
                    title: $0.title,
                    subtitle: $0.subtitle
                )
            }
            continuation?.resume(returning: suggestions)
            continuation = nil
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
