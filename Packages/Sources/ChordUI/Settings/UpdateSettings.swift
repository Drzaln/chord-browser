import AppKit
import ChordUpdater
import SwiftUI

/// The Updates section of the settings sheet: shows the installed version,
/// checks GitHub for a newer release, and drives the download → install →
/// restart flow. All the heavy lifting happens in `ChordUpdater`; this view
/// only renders its `phase`.
struct UpdateSettings: View {
    @State private var controller: UpdateController

    init() {
        let version = Self.currentVersion
        _controller = State(initialValue: UpdateController(
            currentVersion: version,
            releaseChecker: GitHubReleaseChecking(
                repository: "Drzaln/chord-browser",
                userAgent: "Chord/\(version)"
            )
        ))
    }

    /// The installed app's version, read from the bundle. Falls back to 0.0.0
    /// only when a test host strips the Info.plist.
    static var currentVersion: Version {
        let raw = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.0.0"
        return Version(raw: raw) ?? Version(raw: "0.0.0")!
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            switch controller.phase {
            case .idle, .checking:
                checkingRow
            case .upToDate:
                upToDateRow
            case .updateAvailable(let release):
                availableRow(release)
            case .downloading(let fraction):
                downloadingRow(fraction)
            case .extracting:
                installingRow(text: "Extracting…", systemImage: "shippingbox.fill")
            case .installing:
                installingRow(text: "Installing…", systemImage: "arrow.down.circle.fill")
            case .readyToRestart(let url):
                readyToRestartRow(url)
            case .failed(let message):
                failedRow(message)
            }

            actionRow

            Text(
                "Chord checks the GitHub releases page (Drzaln/chord-browser) and "
                    + "updates itself by replacing the copy in Applications. You "
                    + "initiate every step — nothing downloads without a click."
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .task { await checkIfNeeded() }
    }

    // MARK: - Rows

    private var header: some View {
        HStack {
            Text("Updates").font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(verbatim: "Installed \(controller.currentVersion)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var checkingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Checking for updates…")
                .font(.system(size: 12))
        }
    }

    private var upToDateRow: some View {
        Label {
            Text(verbatim: "Chord is up to date (v\(controller.currentVersion)).")
        } icon: {
            Image(systemName: "checkmark.circle.fill")
        }
        .font(.system(size: 12))
        .foregroundStyle(.green)
    }

    private func availableRow(_ release: GitHubRelease) -> some View {
        let message: String = release.version.map { "Version \($0) is available." }
            ?? "A new version is available."
        return VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(verbatim: message)
            } icon: {
                Image(systemName: "arrow.down.circle.fill")
            }
            .font(.system(size: 12, weight: .medium))
            Text(verbatim: "You're on \(controller.currentVersion).")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func downloadingRow(_ fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Downloading…").font(.system(size: 12))
            ProgressView(value: fraction)
                .frame(maxWidth: 300)
        }
    }

    private func installingRow(text: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Label(text, systemImage: systemImage)
                .font(.system(size: 12))
        }
    }

    private func readyToRestartRow(_ url: URL) -> some View {
        Label(
            "Update installed. Restart to finish.",
            systemImage: "checkmark.circle.fill"
        )
        .font(.system(size: 12))
        .foregroundStyle(.green)
    }

    private func failedRow(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11))
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionRow: some View {
        switch controller.phase {
        case .idle, .checking:
            EmptyView()
        case .upToDate, .failed:
            Button("Check for Updates") { Task { await controller.checkForUpdates() } }
        case .updateAvailable:
            Button("Download & Install") {
                Task { await controller.downloadAndInstall() }
            }
        case .downloading, .extracting, .installing:
            EmptyView()
        case .readyToRestart(let url):
            Button("Restart Now") { relaunch(appAt: url) }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Helpers

    /// Runs the first check on appear. A re-visit while the result is still
    /// showing does not hammer the network again — only `idle` and `failed`
    /// re-check.
    private func checkIfNeeded() async {
        if case .idle = controller.phase {
            await controller.checkForUpdates()
        }
    }

    /// Launches the freshly installed app once this instance has quit, then
    /// terminates this instance so the graceful shutdown path (state flush) runs.
    private func relaunch(appAt url: URL) {
        // A detached helper waits for this process to exit — the `open` goes
        // through LaunchServices, which restores windows and entitlements.
        let script = "while pgrep -x Chord > /dev/null; do sleep 0.5; done; open -n \"\(url.path)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        try? process.run()
        NSApp.terminate(nil)
    }
}