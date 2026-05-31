import Foundation
import CoreLocation

/// A captured GPS fix in the manifest's units. Altitude is HAE (WGS84
/// ellipsoidal height) — NEVER MSL. See ADR-007 amendment.
struct LocationFix {
    let latitude: Double
    let longitude: Double
    /// HAE — from `CLLocation.ellipsoidalAltitude`, never `CLLocation.altitude`.
    let altitudeM: Double
    let horizontalAccuracyM: Double
    let verticalAccuracyM: Double
    let timestamp: Date
    /// True if the fix was returned on timeout without reaching the accuracy target.
    let degraded: Bool

    var gpsOrigin: GPSOrigin {
        GPSOrigin(latitude: latitude, longitude: longitude, altitudeM: altitudeM,
                  horizontalAccuracyM: horizontalAccuracyM, verticalAccuracyM: verticalAccuracyM,
                  timestamp: CaptureSessionManifest.iso8601.string(from: timestamp))
    }

    var gpsFix: GPSFix {
        GPSFix(latitude: latitude, longitude: longitude, altitudeM: altitudeM,
               horizontalAccuracyM: horizontalAccuracyM, verticalAccuracyM: verticalAccuracyM)
    }
}

/// The injectable location boundary (so the view model is testable without GPS).
protocol LocationProviding: AnyObject {
    func requestAuthorization()
    /// Waits up to `timeout` for a fix at or better than `targetAccuracyM`,
    /// returning the best available (with `degraded == true`) on timeout.
    func acquireOriginFix(targetAccuracyM: Double, timeout: TimeInterval) async -> LocationFix?
    /// The most recent fix (used per-capture without re-waiting).
    var latestFix: LocationFix? { get }
}

/// CoreLocation implementation. `kCLLocationAccuracyBestForNavigation`; uses
/// `ellipsoidalAltitude` exclusively.
///
/// @MainActor: this class is always created and used from the @MainActor view
/// model, and CL delivers delegate callbacks on the thread the manager was set
/// up on (main here). Annotating the class makes that assumption compiler-
/// enforced rather than documented-only, and ensures `continuation` and
/// `timeoutTask` are touched only on the main actor (race-free by construction).
@MainActor
final class GPSProvider: NSObject, LocationProviding, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var best: CLLocation?
    private var continuation: CheckedContinuation<LocationFix?, Never>?
    private var targetAccuracy: Double = 10.0
    /// Cancelled early when `didUpdateLocations` finds a good-enough fix.
    private var timeoutTask: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
    }

    deinit {
        // Best-effort: stop CL updates when the provider is deallocated.
        // We do not touch `continuation` here — timeoutTask owns resumption.
        manager.stopUpdatingLocation()
    }

    func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    var latestFix: LocationFix? {
        best.map { Self.fix(from: $0, degraded: $0.horizontalAccuracy > targetAccuracy) }
    }

    func acquireOriginFix(targetAccuracyM: Double = 10.0, timeout: TimeInterval = 30.0) async -> LocationFix? {
        targetAccuracy = targetAccuracyM
        manager.startUpdatingLocation()

        let fix: LocationFix? = await withCheckedContinuation { cont in
            self.continuation = cont
            // Structured-concurrency timeout: runs on the main actor (inherits
            // isolation), so touching `best`/`continuation` is race-free.
            // The task is cancelled in `resumeOnce` when a good fix arrives early.
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self else { return }
                let degradedFix = self.best.map {
                    Self.fix(from: $0, degraded: $0.horizontalAccuracy > targetAccuracyM)
                }
                self.resumeOnce(with: degradedFix)
            }
        }
        manager.stopUpdatingLocation()
        return fix
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        if best == nil || loc.horizontalAccuracy < (best?.horizontalAccuracy ?? .greatestFiniteMagnitude) {
            best = loc
        }
        if loc.horizontalAccuracy <= targetAccuracy {
            resumeOnce(with: Self.fix(from: loc, degraded: false))
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Keep waiting for the timeout; a transient failure shouldn't abort.
    }

    // MARK: - Private helpers

    /// Resumes the pending continuation exactly once. Cancels the timeout task
    /// if called before it fires. Safe to call from multiple sites because the
    /// nil-and-swap is performed synchronously on the main actor.
    private func resumeOnce(with fix: LocationFix?) {
        guard let cont = continuation else { return }
        continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        cont.resume(returning: fix)
    }

    private static func fix(from loc: CLLocation, degraded: Bool) -> LocationFix {
        LocationFix(
            latitude: loc.coordinate.latitude,
            longitude: loc.coordinate.longitude,
            // HAE — ellipsoidal height (iOS 15+), NEVER loc.altitude (MSL).
            altitudeM: loc.ellipsoidalAltitude,
            horizontalAccuracyM: loc.horizontalAccuracy,
            verticalAccuracyM: loc.verticalAccuracy,
            timestamp: loc.timestamp,
            degraded: degraded
        )
    }
}
