import Foundation

/// Reads the backend base URL from Info.plist (key `BackendURL`, populated from
/// the build's `.xcconfig` `BACKEND_URL`). Mirrors the Rails `after_initialize`
/// fail-fast-at-boot convention: a misconfigured build dies immediately with a
/// clear message instead of silently 500ing at request time.
///
/// - In non-Debug builds the URL MUST be present and MUST be https. A missing or
///   non-https value is a packaging bug and calls `fatalError` at first access.
/// - In Debug builds a missing value also `fatalError`s (the dev forgot the
///   xcconfig), but http is allowed (localhost).
enum AppConfig {
    /// The configured backend base URL. Resolved once, lazily, at first access.
    static let backendURL: URL = resolveBackendURL()

    /// Capture-session upload endpoint for a given job.
    /// `<backend>/api/v1/capture-sessions/<job_id>`.
    static func captureSessionURL(jobID: String) -> URL {
        backendURL
            .appendingPathComponent("api")
            .appendingPathComponent("v1")
            .appendingPathComponent("capture-sessions")
            .appendingPathComponent(jobID)
    }

    private static func resolveBackendURL() -> URL {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "BackendURL") as? String,
              !raw.isEmpty else {
            fatalError(
                "BackendURL missing from Info.plist. Set BACKEND_URL in the build's " +
                ".xcconfig (Debug.xcconfig / Release.xcconfig)."
            )
        }
        guard let url = URL(string: raw), let scheme = url.scheme else {
            fatalError("BackendURL is not a valid URL: \(raw)")
        }
        #if !DEBUG
        guard scheme == "https" else {
            fatalError("Release builds require an https BackendURL; got \(raw)")
        }
        #endif
        return url
    }
}
