import Foundation

/// What an update has to be: the same app, and from the same signing team when
/// the installed copy has one.
public struct BundleIdentity: Sendable, Equatable {
    public let bundleID: String
    /// Nil for an ad-hoc signature, which names no team.
    public let teamID: String?

    public init(bundleID: String, teamID: String?) {
        self.bundleID = bundleID
        self.teamID = teamID
    }

    /// The app this process is running from. Nil outside an app bundle.
    public static func running() -> BundleIdentity? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        return BundleIdentity(
            bundleID: bundleID, teamID: try? BundleVerifier.teamID(of: Bundle.main.bundleURL))
    }
}

/// Checks a downloaded `.app` before it replaces the installed one.
///
/// Shells out to `/usr/bin/codesign`, as the installer does to `ditto`, so the
/// package stays Foundation-only (Security belongs to `ChordSecrets` and
/// `ChordCrypto`, ADR 011).
///
/// What this proves depends on how releases are signed. With a team signature,
/// the team check means only that team's builds install. With an ad-hoc
/// signature, the checks catch a wrong, mismatched or damaged bundle, and
/// nothing more: anyone can sign ad hoc.
enum BundleVerifier {
    struct Failure: Error, Equatable {
        let message: String
    }

    static func verify(_ app: URL, expected: BundleIdentity, version: Version?) throws {
        let name = app.lastPathComponent
        let info = try infoDictionary(of: app)

        guard let bundleID = info["CFBundleIdentifier"] as? String, bundleID == expected.bundleID else {
            throw Failure(message: "\(name) is a different app, not \(expected.bundleID).")
        }
        guard let version else {
            throw Failure(message: "The release has no version to check \(name) against.")
        }
        guard let raw = info["CFBundleShortVersionString"] as? String, Version(raw: raw) == version else {
            throw Failure(message: "\(name) is not version \(version).")
        }
        guard succeeds(["--verify", "--deep", "--strict", app.path]) else {
            throw Failure(message: "\(name) is damaged, or was changed after it was signed.")
        }
        if let team = expected.teamID {
            guard try teamID(of: app) == team else {
                throw Failure(message: "\(name) is not signed by the team that signed this copy of Chord.")
            }
        }
    }

    /// The signing team of `app`, or nil for an ad-hoc signature. Throws when
    /// the bundle has no readable signature at all.
    static func teamID(of app: URL) throws -> String? {
        let (status, output) = try codesign(["-dvv", app.path])
        guard status == 0 else {
            throw Failure(message: "\(app.lastPathComponent) is not signed.")
        }
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix("TeamIdentifier=") {
            let value = line.dropFirst("TeamIdentifier=".count)
            return value == "not set" || value.isEmpty ? nil : String(value)
        }
        return nil
    }

    private static func infoDictionary(of app: URL) throws -> [String: Any] {
        let url = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let info = plist as? [String: Any]
        else {
            throw Failure(message: "\(app.lastPathComponent) has no readable Info.plist.")
        }
        return info
    }

    private static func succeeds(_ arguments: [String]) -> Bool {
        (try? codesign(arguments).status) == 0
    }

    /// Runs `codesign` and returns its exit status and what it printed (it
    /// reports on stderr).
    private static func codesign(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        // Read before waiting: a full pipe would otherwise block the tool.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
