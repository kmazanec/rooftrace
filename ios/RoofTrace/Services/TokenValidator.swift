import Foundation

/// Validates the job-scoped capture_token and parses the `rooftrace://capture`
/// deep link. The token is a Rails `has_secure_token` value: 32 characters from
/// the base58 (Bitcoin) alphabet — `SecureRandom.base58`. base58 omits the
/// visually ambiguous characters: `0` (zero), `O`, `I`, and `l`.
enum TokenValidator {
    /// The base58 (Bitcoin) alphabet, matching Ruby's `SecureRandom.base58`.
    static let base58Alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

    private static let base58Set = Set(base58Alphabet)

    /// True iff `token` is exactly 32 base58 characters.
    static func isValid(_ token: String) -> Bool {
        guard token.count == 32 else { return false }
        return token.allSatisfy { base58Set.contains($0) }
    }

    /// True iff `jobID` is a syntactically valid UUID.
    static func isValidJobID(_ jobID: String) -> Bool {
        UUID(uuidString: jobID) != nil
    }

    /// The exact `Authorization` header value: `"Bearer <token>"` (single space).
    static func bearerHeaderValue(_ token: String) -> String {
        "Bearer \(token)"
    }

    /// Parses `rooftrace://capture?token=...&job_id=...`. Returns nil unless the
    /// scheme is `rooftrace` and a non-empty `token` query item is present.
    static func parseDeepLink(_ url: URL) -> (token: String, jobID: String?)? {
        guard url.scheme == "rooftrace" else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else { return nil }
        let token = items.first { $0.name == "token" }?.value
        guard let token, !token.isEmpty else { return nil }
        let jobID = items.first { $0.name == "job_id" }?.value
        return (token: token, jobID: jobID)
    }
}
