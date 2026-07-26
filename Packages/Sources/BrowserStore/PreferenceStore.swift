import Foundation

/// The two operations `Preferences` needs from a key-value store.
///
/// Exists so tests do not have to touch `UserDefaults`. A test cannot simply use
/// `UserDefaults(suiteName:)` and clean up after itself: registering a suite
/// makes a *persistent* domain, and `cfprefsd` recreates the (now empty) plist
/// at process exit however carefully the domain is removed first — so every run
/// left another `chord.tests.*` file in `~/Library/Preferences`.
///
/// `UserDefaults` conforms as-is; the real app is unchanged.
public protocol PreferenceStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: PreferenceStore {}

/// A `PreferenceStore` that lives and dies with the test using it.
///
/// In the shipping target rather than a test target because `BrowserTestSupport`
/// deliberately does not depend on Store (it is Core + Engine, see Package.swift).
public final class InMemoryPreferenceStore: PreferenceStore {
    private var values: [String: Any] = [:]

    public init(_ values: [String: Any] = [:]) {
        self.values = values
    }

    public func object(forKey key: String) -> Any? { values[key] }

    public func set(_ value: Any?, forKey key: String) {
        if let value {
            values[key] = value
        } else {
            values.removeValue(forKey: key)
        }
    }
}
