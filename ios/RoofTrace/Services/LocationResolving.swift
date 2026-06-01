import CoreLocation
import Foundation
import UIKit

enum LocationPermission: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
}

protocol LocationResolving: Sendable {
    var permission: LocationPermission { get async }
    func requestPermission() async -> LocationPermission
    func reverseGeocodeCurrentLocation() async throws -> String
}

enum LocationResolverError: Error {
    case permissionDenied
    case unavailable
}

@MainActor
final class CoreLocationResolver: NSObject, LocationResolving, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var locationContinuation: CheckedContinuation<CLLocation, Error>?
    private var permissionContinuation: CheckedContinuation<LocationPermission, Never>?

    override init() {
        super.init()
        manager.delegate = self
    }

    var permission: LocationPermission {
        get async { Self.map(manager.authorizationStatus) }
    }

    func requestPermission() async -> LocationPermission {
        switch manager.authorizationStatus {
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                permissionContinuation = continuation
                manager.requestWhenInUseAuthorization()
            }
        default:
            return Self.map(manager.authorizationStatus)
        }
    }

    func reverseGeocodeCurrentLocation() async throws -> String {
        guard await permission == .authorized else {
            throw LocationResolverError.permissionDenied
        }
        let location = try await currentLocation()
        guard let placemark = try await geocoder.reverseGeocodeLocation(location).first else {
            throw LocationResolverError.unavailable
        }
        let parts = [
            placemark.subThoroughfare,
            placemark.thoroughfare,
            placemark.locality,
            placemark.administrativeArea,
            placemark.postalCode
        ]
        let address = parts.compactMap(\.self).filter { !$0.isEmpty }.joined(separator: " ")
        guard !address.isEmpty else { throw LocationResolverError.unavailable }
        return address
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            permissionContinuation?.resume(returning: Self.map(manager.authorizationStatus))
            permissionContinuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            guard let location = locations.last else {
                locationContinuation?.resume(throwing: LocationResolverError.unavailable)
                locationContinuation = nil
                return
            }
            locationContinuation?.resume(returning: location)
            locationContinuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            locationContinuation?.resume(throwing: error)
            locationContinuation = nil
        }
    }

    private func currentLocation() async throws -> CLLocation {
        try await withCheckedThrowingContinuation { continuation in
            locationContinuation = continuation
            manager.requestLocation()
        }
    }

    private static func map(_ status: CLAuthorizationStatus) -> LocationPermission {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            .authorized
        case .notDetermined:
            .notDetermined
        case .denied, .restricted:
            .denied
        @unknown default:
            .denied
        }
    }
}
