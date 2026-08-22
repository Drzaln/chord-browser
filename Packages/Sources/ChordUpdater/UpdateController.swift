import Foundation
import Observation

/// The update flow as observable state, driving the Settings UI. One instance
/// per app — the UI keeps it alive. Holds no AppKit types, so the package stays
/// Foundation-only; relaunching is the caller's job.
@MainActor
@Observable
public final class UpdateController {
    public enum Phase: Equatable, Sendable {
        case idle
        case checking
        case upToDate
        case updateAvailable(GitHubRelease)
        case downloading(Double)
        case extracting
        case installing
        case readyToRestart(URL)
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public let currentVersion: Version

    /// Minimum time between non-forced checks. The check runs on Settings open;
    /// a cooldown stops a Settings session from hammering GitHub's 60 req/hr
    /// unauthenticated budget.
    private static let checkCooldown: TimeInterval = 300 // 5 minutes

    private var lastCheckedAt: Date?

    private let releaseChecker: any ReleaseChecking
    private let installer: AppInstaller

    public init(
        currentVersion: Version,
        releaseChecker: any ReleaseChecking,
        installer: AppInstaller = AppInstaller()
    ) {
        self.currentVersion = currentVersion
        self.releaseChecker = releaseChecker
        self.installer = installer
    }

    /// Whether a newer release is known and not yet downloaded.
    public var hasUpdate: Bool {
        if case .updateAvailable = phase { return true }
        return false
    }

    /// Compares the latest GitHub release against `currentVersion` and moves
    /// the state forward. Never downloads. `force` bypasses the cooldown for an
    /// explicit user click; automatic checks (Settings open) are throttled.
    public func checkForUpdates(force: Bool = false) async {
        if !force, let lastCheckedAt, Date().timeIntervalSince(lastCheckedAt) < Self.checkCooldown {
            return
        }
        lastCheckedAt = Date()
        phase = .checking
        do {
            guard let release = try await releaseChecker.latestRelease() else {
                phase = .upToDate
                return
            }
            guard !release.isPrerelease else {
                phase = .upToDate
                return
            }
            guard let latest = release.version else {
                phase = .failed("The release tag “\(release.tagName)” is not a version.")
                return
            }
            phase = latest > currentVersion ? .updateAvailable(release) : .upToDate
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Downloads the update's zip, extracts it, and moves the `.app` into
    /// `/Applications`. Assumes a prior successful `checkForUpdates()`.
    public func downloadAndInstall() async {
        guard case .updateAvailable(let release) = phase,
              let asset = release.zipAsset else { return }
        phase = .downloading(0)
        do {
            let installedURL = try await installer.install(
                release: release,
                asset: asset,
                progress: { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        self?.phase = .downloading(fraction)
                    }
                }
            )
            phase = .readyToRestart(installedURL)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}