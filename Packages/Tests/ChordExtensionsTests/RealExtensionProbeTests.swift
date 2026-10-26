import ChordCore
@testable import ChordExtensions
import Foundation
import Testing

/// Opt-in probe against real Chrome Web Store bundles. It is skipped unless
/// `CHORD_REAL_EXTENSIONS=1`, so prepush never depends on the network.
@MainActor
struct RealExtensionProbeTests {
    private static let ids = [
        "1password": "aeblfdkhhhdcdjpifhhbdiojplfjncoa",
        "bitwarden": "nngceckbapebfimnlniiiahkandclblb",
        "tampermonkey": "dhdgffkkebhmkfjojejmpbldmpobfkfo",
        "ublock-lite": "ddkjiahejlhfcafbddmgiahcphecmpfh",
        "ublock-origin-mv2": "cjpalhdlnbpafiamejdnhcphjbkeiagm",
    ]

    @Test func loadRealExtensions() async throws {
        guard ProcessInfo.processInfo.environment["CHORD_REAL_EXTENSIONS"] == "1" else {
            return
        }
        let root = FileManager.default.temporaryDirectory
            .appending(path: "chord-real-ext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for (name, id) in Self.ids {
            do {
                let data = try await Crx.fetch(id)
                let installer = ExtensionInstaller(
                    extensionsDirectory: root.appending(path: name)
                )
                let installed = try installer.install(
                    data: data, sourceName: "\(id).crx", fromStore: true
                )
                let host = WebKitExtensionHost()
                let space = Space(name: "Probe", sortIndex: 0)
                let loaded = try await host.load(installed, in: space)
                let context = host.context(forSlug: installed.slug, in: space)
                if let context {
                    let manifest = context.webExtension.manifest
                    let perms = manifest["permissions"] as? [String] ?? []
                    print("PROBE \(name) manifestNative=\(perms.contains("nativeMessaging")) requested=\(context.webExtension.requestedPermissions.map(\.rawValue)) status=\(String(describing: context.permissionStatus(for: .nativeMessaging)))")
                }
                try? await Task.sleep(for: .seconds(2))
                let errors = (context?.errors ?? []).map { error -> String in
                    let e = error as NSError
                    let under = (e.userInfo[NSUnderlyingErrorKey] as? NSError)
                        .map { " ← \($0.localizedDescription)" } ?? ""
                    return e.localizedDescription + under
                }
                print("PROBE \(name) OK loaded=\(loaded.displayName ?? "?") version=\(loaded.manifestVersion) worker=\(loaded.hasBackgroundContent) actions=\(host.actions(in: space).map(\.label)) errors=\(errors)")
            } catch {
                print("PROBE \(name) FAILED \(error)")
            }
        }
    }
}
