import CoreLocation
import Foundation

/// Wraps GPS. Hands out distance in small accepted chunks and keeps running
/// with the screen locked (background location mode).
final class LocationTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var accuracy: Double?
    @Published private(set) var authorization: CLAuthorizationStatus
    /// Smoothed speed over the last ~10 s, in m/s.
    @Published private(set) var speed: Double?

    /// Most recent fix good enough to record (≤ 25 m accuracy).
    private(set) var latest: CLLocation?

    /// Called with metres covered since the last accepted fix.
    var onDistance: ((Double) -> Void)?
    /// Called with every recent fix good enough for route guidance (≤ 40 m).
    var onFix: ((CLLocation) -> Void)?
    /// Called after every batch of location updates.
    var onUpdate: (() -> Void)?

    private let manager = CLLocationManager()
    private var last: CLLocation?
    private var counting = false
    private var recentSpeeds: [(Date, Double)] = []

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
    }

    /// Start GPS before the run so it has a fix by the time you press Start.
    func warmUp() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.startUpdatingLocation()
    }

    func beginCounting() {
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        last = nil
        counting = true
        manager.startUpdatingLocation()
    }

    func pauseCounting() {
        counting = false
        last = nil
    }

    func resumeCounting() {
        last = nil
        counting = true
    }

    func stop() {
        counting = false
        last = nil
        latest = nil
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        if authorization == .authorizedWhenInUse || authorization == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations {
            guard location.horizontalAccuracy >= 0 else { continue }
            accuracy = location.horizontalAccuracy
            if location.speed >= 0 { recordSpeed(location.speed, at: location.timestamp) }

            if location.horizontalAccuracy <= 40, abs(location.timestamp.timeIntervalSinceNow) < 10 {
                onFix?(location)
            }
            guard location.horizontalAccuracy <= 25,
                  abs(location.timestamp.timeIntervalSinceNow) < 10 else { continue }
            latest = location
            guard counting else { continue }

            guard let previous = last else {
                last = location
                continue
            }

            let metres = location.distance(from: previous)
            let seconds = location.timestamp.timeIntervalSince(previous.timestamp)

            // Ignore GPS jumps faster than a sprint.
            if seconds > 0, metres / seconds > 12 {
                last = location
                continue
            }
            // Hold small moves until they add up, so standing still doesn't creep.
            if metres >= 3 {
                onDistance?(metres)
                last = location
            }
        }
        onUpdate?()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient GPS errors are normal; keep going.
    }

    private func recordSpeed(_ value: Double, at time: Date) {
        recentSpeeds.append((time, value))
        recentSpeeds.removeAll { time.timeIntervalSince($0.0) > 10 }
        let values = recentSpeeds.map(\.1)
        speed = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}
