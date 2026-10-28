import ChordCore
@testable import ChordExtensions
import Foundation
import Testing

/// Opt-in probe against real Chrome Web Store bundles. It is skipped unless
/// `CHORD_REAL_EXTENSIONS=1`, so prepush never depends on the network.
///
/// This is the automated half of the M9e matrix (CHECKPOINT): it records
/// install, load/context errors, worker presence, toolbar action, popup,
/// declared content scripts, native-messaging hosts, offscreen and side-panel
/// declarations. Content-script execution, live popup rendering and worker
/// revival are checked in the temp-world app run; a unit test can only see what
/// WebKit reports at load.
@MainActor
struct RealExtensionProbeTests {
    private static let ids = [
        "ublock-lite": "ddkjiahejlhfcafbddmgiahcphecmpfh",
        "bitwarden": "nngceckbapebfimnlniiiahkandclblb",
        "tampermonkey": "dhdgffkkebhmkfjojejmpbldmpobfkfo",
        "1password": "aeblfdkhhhdcdjpifhhbdiojplfjncoa",
        "claude": "fcoeoabgfenejglbffodgkkbkcdhcgfn",
        "figma": "fkmaohpngenfoccdgceedjkfhkdcohmg",
        "loom": "liecbddmkiiihnedobmlmillhodjkdmb",
        "awesome-screenshot": "nlipoenfbbikpbjkfpfillcgkoblgpmj",
    ]

    /// Answers the Store-side shim calls a real bundle makes during startup.
    /// Without it the host reports "isn't available in Chord yet" for every
    /// `sidePanel`/bookmarks/history call, which would read as a compatibility
    /// failure when the real app has the service wired.
    @MainActor
    private final class ProbeShimData: ExtensionShimData {
        var calls: [String: Int] = [:]

        func answer(
            _ api: String, args: [Any], context: ExtensionShimContext
        ) async throws -> Any? {
            calls[api, default: 0] += 1
            switch api {
            case "sidePanel.getOptions":
                return ["enabled": true, "path": "sidepanel.html"]
            case "sidePanel.getPanelBehavior":
                return ["openPanelOnActionClick": false]
            case "bookmarks.getTree":
                return [[
                    "id": "0", "title": "", "children": [[
                        "id": "1", "parentId": "0", "title": "Bookmarks Bar",
                        "children": [],
                    ]],
                ]]
            case "history.search", "downloads.search", "topSites.get",
                 "sessions.getRecentlyClosed":
                return []
            case "tabGroups.query":
                return []
            default:
                return nil
            }
        }
    }

    @Test func loadRealExtensions() async throws {
        guard ProcessInfo.processInfo.environment["CHORD_REAL_EXTENSIONS"] == "1" else {
            return
        }
        let root = FileManager.default.temporaryDirectory
            .appending(path: "chord-real-ext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var installed = 0
        var clean = 0
        for (name, id) in Self.ids {
            do {
                let data = try await Crx.fetch(id)
                let installer = ExtensionInstaller(
                    extensionsDirectory: root.appending(path: name)
                )
                let bundle = try installer.install(
                    data: data, sourceName: "\(id).crx", fromStore: true
                )
                #expect(
                    bundle.signatureStatus != .unsupported,
                    "the store's CRX3 signature must be checked, not skipped"
                )
                installed += 1
                let host = WebKitExtensionHost()
                let shim = ProbeShimData()
                host.shimData = shim
                let space = Space(name: "Probe", sortIndex: 0)
                let loaded = try await host.load(bundle, in: space)
                let context = host.context(forSlug: bundle.slug, in: space)
                // Give the background worker a moment to report startup errors.
                try? await Task.sleep(for: .seconds(2))
                let manifest = context?.webExtension.manifest ?? [:]
                let permissions = manifest["permissions"] as? [String] ?? []
                let nativeHosts = manifest["nativeMessagingHosts"] as? [String] ?? []
                let contentScripts = manifest["content_scripts"] as? [[String: Any]] ?? []
                let contentMatches = contentScripts.flatMap {
                    $0["matches"] as? [String] ?? []
                }
                let hasSidePanel = manifest["side_panel"] != nil
                    || permissions.contains("sidePanel")
                let actions = host.actions(in: space)
                let errors = (context?.errors ?? []).map { error -> String in
                    let e = error as NSError
                    let under = (e.userInfo[NSUnderlyingErrorKey] as? NSError)
                        .map { " ← \($0.localizedDescription)" } ?? ""
                    return e.localizedDescription + under
                }
                if errors.isEmpty { clean += 1 }
                print(
                    """
                    PROBE \(name) OK id=\(bundle.identifier) \
                    name=\(loaded.displayName ?? "?") mv=\(loaded.manifestVersion) \
                    signature=\(bundle.signatureStatus.rawValue) \
                    worker=\(loaded.hasBackgroundContent) \
                    actions=\(actions.map(\.label)) \
                    popup=\(actions.map(\.presentsPopup)) \
                    contentScripts=\(contentScripts.count)/\(contentMatches.count) matches \
                    nativeHosts=\(nativeHosts) \
                    offscreen=\(permissions.contains("offscreen")) \
                    desktopCapture=\(permissions.contains("desktopCapture")) \
                    tabCapture=\(permissions.contains("tabCapture")) \
                    sidePanel=\(hasSidePanel) \
                    allHosts=\(context?.hasAccessToAllHosts ?? false) \
                    shimCalls=\(shim.calls.sorted { $0.key < $1.key }) \
                    errors=\(errors)
                    """
                )
            } catch {
                print("PROBE \(name) FAILED \(error)")
            }
        }
        print("PROBE SUMMARY installed=\(installed)/\(Self.ids.count) clean=\(clean)/\(installed)")
    }
}
