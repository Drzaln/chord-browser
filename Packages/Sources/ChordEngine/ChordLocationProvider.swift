import ChordCore
import CoreLocation
import Foundation

/// Supplies a page's shimmed `navigator.geolocation` with real coordinates
/// (non-spec: user-requested).
///
/// macOS WKWebView has no geolocation provider: WebKit's built-in CoreLocation
/// provider is iOS-only (`WKGeolocationProviderIOS`), so the geolocation
/// permission delegate — the route Orion uses — never fires on macOS. The page
/// therefore talks to a shim (see `GeolocationBridge`), whose position requests
/// land here, where the host's own `CLLocationManager` answers.
///
/// The OS TCC prompt (backed by `NSLocationWhenInUseUsageDescription` in
/// Info.plist) appears the first time a *granted* site asks for a position:
/// `requestWhenInUseAuthorization()` is what makes the app appear in System
/// Settings → Privacy → Location Services, exactly as camera/mic do.
@MainActor
final class ChordLocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    /// The one outstanding fix request. `CLLocationManager` answers one at a
    /// time, so a second concurrent request is refused rather than queued.
    private var pending: CheckedContinuation<WebGeolocationCoordinate?, Never>?
    /// Outstanding OS-authorization wait, resumed in
    /// `locationManagerDidChangeAuthorization` when the TCC prompt is answered.
    private var authPending: CheckedContinuation<Bool, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    /// One position fix, or nil when the user has not authorized the app, the
    /// fix failed, or a fix is already in flight. First call after launch
    /// surfaces the OS authorization prompt and waits for the answer before
    /// requesting the fix — so the first attempt succeeds rather than racing
    /// the TCC prompt.
    func currentPosition() async -> WebGeolocationCoordinate? {
        guard pending == nil else { return nil }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return await requestFix()
        case .notDetermined:
            // Trigger the OS prompt; this is what makes the app appear in
            // System Settings → Privacy → Location Services, exactly as
            // camera/mic do.
            manager.requestWhenInUseAuthorization()
            let granted = await withCheckedContinuation { continuation in
                authPending = continuation
            }
            guard granted else { return nil }
            return await requestFix()
        case .denied, .restricted:
            return nil
        @unknown default:
            return nil
        }
    }

    private func requestFix() async -> WebGeolocationCoordinate? {
        guard pending == nil else { return nil }
        return await withCheckedContinuation { continuation in
            pending = continuation
            manager.requestLocation()
        }
    }

    private func finish(_ coordinate: WebGeolocationCoordinate?) {
        pending?.resume(returning: coordinate)
        pending = nil
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]
    ) {
        let coordinate = locations.last.map(WebGeolocationCoordinate.init(location:))
        Task { @MainActor in self.finish(coordinate) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let granted: Bool
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: granted = true
        default: granted = false
        }
        Task { @MainActor in
            self.authPending?.resume(returning: granted)
            self.authPending = nil
        }
    }
}

extension WebGeolocationCoordinate {
    /// Builds the Core shape from a CoreLocation fix. `course`/`speed` are
    /// reported as 0 by CoreLocation when unknown; the web spec wants null.
    init(location: CLLocation) {
        self.init(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            accuracy: location.horizontalAccuracy,
            altitude: location.verticalAccuracy >= 0 ? location.altitude : nil,
            altitudeAccuracy: location.verticalAccuracy >= 0 ? location.verticalAccuracy : nil,
            heading: location.course >= 0 ? location.course : nil,
            speed: location.speed >= 0 ? location.speed : nil,
            timestamp: location.timestamp
        )
    }
}