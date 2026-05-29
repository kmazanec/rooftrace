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
final class GPSProvider: NSObject, LocationProviding, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var best: CLLocation?
    private var continuation: CheckedContinuation<LocationFix?, Never>?
    private var targetAccuracy: Double = 10.0

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
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
            // Timeout: resolve with the best available so far (degraded).
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, let cont = self.continuation else { return }
                self.continuation = nil
                let result = self.best.map { Self.fix(from: $0, degraded: $0.horizontalAccuracy > targetAccuracyM) }
                cont.resume(returning: result)
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
        if loc.horizontalAccuracy <= targetAccuracy, let cont = continuation {
            continuation = nil
            cont.resume(returning: Self.fix(from: loc, degraded: false))
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Keep waiting for the timeout; a transient failure shouldn't abort.
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
