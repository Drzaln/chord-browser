import Foundation

/// One location fix, carried from the engine's `navigator.geolocation` shim to
/// the page. WebKit-free, so it can live in Core and be built from a
/// `CLLocation` inside the engine without leaking CoreLocation upward.
public struct WebGeolocationCoordinate: Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double
    /// Horizontal accuracy in metres.
    public let accuracy: Double
    /// Altitude in metres above mean sea level; nil when unavailable.
    public let altitude: Double?
    /// Vertical accuracy in metres; nil when unavailable.
    public let altitudeAccuracy: Double?
    /// Heading in degrees clockwise from true north; nil when unavailable.
    public let heading: Double?
    /// Ground speed in m/s; nil when unavailable.
    public let speed: Double?
    /// When the fix was taken.
    public let timestamp: Date

    public init(
        latitude: Double,
        longitude: Double,
        accuracy: Double,
        altitude: Double?,
        altitudeAccuracy: Double?,
        heading: Double?,
        speed: Double?,
        timestamp: Date
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
        self.altitude = altitude
        self.altitudeAccuracy = altitudeAccuracy
        self.heading = heading
        self.speed = speed
        self.timestamp = timestamp
    }
}

/// The web-facing geolocation permission state, mirroring the OS authorization
/// so the shimmed `navigator.geolocation` / `navigator.permissions.query`
/// reflect the remembered per-origin decision instead of resetting to `prompt`
/// on every page load.
public enum WebGeolocationPermission: String, Sendable, Equatable {
    /// Not yet decided — the site has not been asked.
    case notDetermined = "prompt"
    case granted
    case denied

    /// The JS-spec string a page reads from `Permissions.status.state`.
    public var jsValue: String { rawValue }
}