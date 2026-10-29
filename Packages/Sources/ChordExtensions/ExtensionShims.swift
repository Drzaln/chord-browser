import AppKit
import AVFoundation
import CryptoKit
import Foundation
import NaturalLanguage
import UserNotifications
import WebKit

/// The small part of Chrome's extension package format Chord changes after a
/// bundle has been verified: the shim that fills APIs WebKit does not provide.
///
/// The rewrite happens on the extracted copy, never on the signed ZIP. It is
/// deliberately minimal in this milestone: `chrome.offscreen` and the native
/// bridge's `chord` endpoint. Future API shims grow here without changing the
/// install layout.
public enum ExtensionShims {
    public static let application = "chord"
    public static let file = "chord-shim.js"
    public static let stamp = ".chord-shim"
    public static let added = ".chord-added"
    public static let marker = "/* Chord: Chrome APIs WebKit lacks (ExtensionShims.swift) */"
    public static let ender = "/* Chord: end of shim */"
    public static let version = "2"
    /// The Chrome version extension pages see. Kept current deliberately:
    /// some extensions gate features on it (1Password opens its unlock popup
    /// only from Chrome 149).
    public static let chromeVersion = "156.0.0.0"

    /// Write the shim into `folder` and wire it into the extension's worker,
    /// content scripts and HTML pages. `fresh` removes only Chord's own
    /// sidecars; a package's copy of those names is never trusted.
    public static func prepare(_ folder: URL, fresh: Bool = false) throws {
        let fm = FileManager.default
        if fresh {
            for name in [stamp, added] {
                try? fm.removeItem(at: folder.appendingPathComponent(name))
            }
        }
        let stampURL = folder.appendingPathComponent(stamp)
        if (try? String(contentsOf: stampURL, encoding: .utf8)) == version { return }

        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
            as? [String: Any]
        else { throw ExtensionShimError.invalidManifest }

        let preparedScript = shim(for: folder)
            .replacingOccurrences(of: "__SEARCH_EVENTS__", with: eventList(in: folder))
            .replacingOccurrences(of: "__SEARCH_SCRIPTS__", with: scriptList(in: folder))
            .replacingOccurrences(of: "__SEARCH_CHROME__", with: chromeVersion)
            .replacingOccurrences(of: "__SEARCH_VERBOSE__", with: "false")
            .replacingOccurrences(of: "__SEARCH_WORKER_GENERATION__", with: "0")
        try preparedScript.write(
            to: folder.appendingPathComponent(file), atomically: true, encoding: .utf8
        )

        var permissions = manifest["permissions"] as? [Any] ?? []
        let optional = manifest["optional_permissions"] as? [Any] ?? []
        let asked = Set((permissions + optional).compactMap { $0 as? String })
        var addedPermissions = (try? JSONSerialization.jsonObject(
            with: Data(contentsOf: folder.appendingPathComponent(added))
        )) as? [String] ?? []
        // The shim reaches the browser through native messaging. Add the
        // permission only when the manifest did not ask for it, and record
        // that Chord added it so the permission sheet can tell the truth.
        if !asked.contains("nativeMessaging") {
            permissions.append("nativeMessaging")
            addedPermissions.append("nativeMessaging")
        }
        // WebKit carries out user scripts through its registered content
        // scripts, which need `scripting`; Chrome grants that as part of
        // `userScripts`, so add it only when the extension asked for the
        // latter and record that Chord did so.
        if asked.contains("userScripts"), !asked.contains("scripting") {
            permissions.append("scripting")
            addedPermissions.append("scripting")
        }
        manifest["permissions"] = permissions

        if var background = manifest["background"] as? [String: Any] {
            if let worker = background["service_worker"] as? String,
               let url = inside(worker, of: folder),
               var source = try? String(contentsOf: url, encoding: .utf8)
            {
                source = removingShim(from: source)
                let module = (background["type"] as? String)?.lowercased() == "module"
                let first = "import \"/\(file)\";\n"
                while source.hasPrefix(first) { source.removeFirst(first.count) }
                let rewritten = module
                    ? first + source
                    : marker + "\n" + preparedScript + "\n" + ender + "\n" + source
                try rewritten.write(to: url, atomically: true, encoding: .utf8)
            }
            if var scripts = background["scripts"] as? [String] {
                if scripts.first != file { scripts.insert(file, at: 0) }
                background["scripts"] = scripts
            }
            manifest["background"] = background
        }

        if let entries = manifest["content_scripts"] as? [[String: Any]] {
            manifest["content_scripts"] = entries.map { entry -> [String: Any] in
                var entry = entry
                if var js = entry["js"] as? [String] {
                    if !js.contains(file) { js.insert(file, at: 0) }
                    entry["js"] = js
                }
                return entry
            }
        }

        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes]
        )
        try manifestData.write(to: manifestURL, options: .atomic)

        // Every extension page — popup, options, offscreen, background page —
        // gets the shim before its own scripts.
        let walker = fm.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        while let url = walker?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  url.pathExtension.lowercased() == "html",
                  url.lastPathComponent != file
            else { continue }
            guard var html = try? String(contentsOf: url, encoding: .utf8),
                  !html.contains(file)
            else { continue }
            let tag = "<script src=\"/\(file)\"></script>"
            if let head = html.range(
                of: "<head(?:\\s[^>]*)?>",
                options: [.regularExpression, .caseInsensitive]
            ) {
                html.insert(contentsOf: tag, at: head.upperBound)
            } else {
                html = tag + html
            }
            try? html.write(to: url, atomically: true, encoding: .utf8)
        }

        if let data = try? JSONSerialization.data(
            withJSONObject: Array(Set(addedPermissions)).sorted()
        ) {
            try? data.write(to: folder.appendingPathComponent(added), options: .atomic)
        }
        try version.write(to: stampURL, atomically: true, encoding: .utf8)
    }

    /// Whether the extension's own manifest asks for native messaging. The
    /// `nativeMessaging` permission Chord adds for its shim does not count.
    @MainActor
    public static func asksForNative(in folder: URL, context: WKWebExtensionContext?) -> Bool {
        guard let context else { return false }
        let requested = context.webExtension.requestedPermissions.contains(.nativeMessaging)
            || context.webExtension.optionalPermissions.contains(.nativeMessaging)
        guard requested else { return false }
        // If Chord added nativeMessaging for its own shim, the extension did
        // not ask for it and must not reach a host on this Mac.
        let added = Set((try? JSONSerialization.jsonObject(
            with: Data(contentsOf: folder.appendingPathComponent(self.added))
        )) as? [String] ?? [])
        return !added.contains("nativeMessaging")
    }

    /// The full Chrome compatibility script, with the event/script names this
    /// extension uses filled in.
    public static var script: String { ExtensionShimScript.javascript }

    nonisolated private static func shim(for folder: URL) -> String {
        ExtensionShimScript.javascript
    }

    /// The events this extension's own code mentions, so its worker can take
    /// listeners that WebKit only allows while it starts.
    nonisolated private static func eventList(in folder: URL) -> String {
        var found = Set<String>()
        let pattern = try! NSRegularExpression(
            pattern: #"\.([a-zA-Z]+)\.(on[A-Z][A-Za-z]+)\b"#
        )
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "js", url.lastPathComponent != file,
                  var text = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            if text.hasPrefix(marker), let end = text.range(of: ender) {
                text = String(text[end.upperBound...])
            }
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let a = Range(match.range(at: 1), in: text),
                      let b = Range(match.range(at: 2), in: text)
                else { continue }
                found.insert("\(text[a]).\(text[b])")
            }
        }
        let data = (try? JSONSerialization.data(withJSONObject: found.sorted())) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// Every JavaScript file the package ships, so `importScripts` can fail
    /// immediately on a missing one instead of letting WebKit's startup hang.
    nonisolated private static func scriptList(in folder: URL) -> String {
        var scripts: [String] = []
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "js" else { continue }
            let path = String(url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count))
            let empty = ((try? String(contentsOf: url, encoding: .utf8)) ?? "x")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            scripts.append((empty ? "-" : "") + path)
        }
        let data = (try? JSONSerialization.data(withJSONObject: scripts.sorted())) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    // MARK: - package paths

    /// Resolve a manifest path inside the extension. A `..`, a symlink, or a
    /// path that lands outside the package is refused rather than rewritten.
    nonisolated private static func inside(_ name: String, of folder: URL) -> URL? {
        let root = folder.standardizedFileURL
        let path = root.appendingPathComponent(
            name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        ).standardizedFileURL
        guard path.path.hasPrefix(root.path + "/"),
              (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              path.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/")
        else { return nil }
        return path
    }

    nonisolated private static func removingShim(from source: String) -> String {
        var text = source
        if text.hasPrefix(marker), let end = text.range(of: ender) {
            text = String(String(text[end.upperBound...]).trimmingPrefix("\n"))
        }
        while text.hasPrefix(marker), let end = text.range(of: "\n})();\n") {
            text = String(text[end.upperBound...])
        }
        return text
    }
}

/// The WebKit-free context a native shim call needs.
public struct ExtensionShimContext: Sendable {
    public let identifier: String
    public let spaceID: UUID
    /// The library slug, for app surfaces that key on it (side panel, UI).
    public let slug: String

    public init(identifier: String, spaceID: UUID, slug: String = "") {
        self.identifier = identifier
        self.spaceID = spaceID
        self.slug = slug
    }
}

/// The Store-side half of the Chrome shim: history, downloads, bookmarks,
/// side panel, tab groups and anything else that lives above the WebKit
/// boundary. Implemented in `ChordStore`; the host forwards unknown shim
/// calls here. `nil` means "not wired yet" and the shim call is refused.
@MainActor
public protocol ExtensionShimData: AnyObject {
    func answer(
        _ api: String, args: [Any], context: ExtensionShimContext
    ) async throws -> Any?
}

public enum ExtensionShimError: Error, LocalizedError, CustomStringConvertible {
    case invalidManifest
    case invalidIdentifier

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .invalidManifest: "the extension has no readable manifest.json"
        case .invalidIdentifier: "the extension has no valid Chrome identifier"
        }
    }
}

/// The in-process endpoint behind `chrome.runtime.sendNativeMessage("chord")`.
///
/// It answers only the APIs Chord supplies itself. A real native host on this
/// Mac goes through `ExtensionNative`; the two must never be confused, because
/// this endpoint is reachable by every extension while a host requires the
/// `nativeMessaging` permission.
@MainActor
enum ExtensionShimBroker {
    private static let speaker = AVSpeechSynthesizer()

    static func answer(
        _ message: Any, context: WKWebExtensionContext, spaceID: UUID,
        host: WebKitExtensionHost? = nil
    ) async throws -> Any? {
        guard let body = message as? [String: Any],
              let api = body["api"] as? String
        else { return ["error": "Not a Chord message"] }
        let args = body["args"] as? [Any] ?? []
        do {
            let value = try await run(
                api, args, context: context, spaceID: spaceID, host: host
            )
            return ["value": value ?? NSNull()]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    private static func run(
        _ api: String, _ args: [Any], context: WKWebExtensionContext,
        spaceID: UUID, host: WebKitExtensionHost?
    ) async throws -> Any? {
        switch api {
        case "offscreen.createDocument", "offscreen.closeDocument",
             "offscreen.hasDocument", "offscreen.sendMessage":
            guard declared("offscreen", in: context) else {
                throw Unsupported(what: "The extension never asked for “offscreen”")
            }
        default:
            break
        }

        switch api {
        case "capture.grant":
            // A worker has no page to record in: chooseDesktopMedia gets an
            // id now, and one of its pages redeems it through getUserMedia.
            guard let host else {
                throw Unsupported(what: "Extension is not loaded")
            }
            return host.capture.grant(for: context)
        case "offscreen.createDocument":
            let options = args.first as? [String: Any] ?? [:]
            guard let path = options["url"] as? String, !path.isEmpty else {
                throw Unsupported(what: "No page for the offscreen document")
            }
            let reasons = options["reasons"] as? [String] ?? []
            try await ExtensionOffscreen.create(
                path: path, reasons: reasons, context: context,
                spaceID: spaceID, capture: host?.capture
            )
            return nil
        case "offscreen.closeDocument":
            ExtensionOffscreen.close(
                identifier: context.uniqueIdentifier, spaceID: spaceID
            )
            return nil
        case "offscreen.hasDocument":
            return ExtensionOffscreen.hasDocument(
                identifier: context.uniqueIdentifier, spaceID: spaceID
            )
        case "offscreen.sendMessage":
            guard args.count == 3, let token = args[0] as? String,
                  let sender = args[2] as? [String: Any]
            else { return ["handled": false] }
            return try await ExtensionOffscreen.send(
                args[1], sender: sender, token: token,
                identifier: context.uniqueIdentifier, spaceID: spaceID
            )
        case "identity.launchWebAuthFlow":
            guard declared("identity", in: context) else {
                throw Unsupported(what: "The extension never asked for “identity”")
            }
            let options = args.first as? [String: Any] ?? [:]
            guard let raw = options["url"] as? String, let url = URL(string: raw) else {
                throw Unsupported(what: "The authorization page could not be loaded.")
            }
            let store = context.webViewConfiguration?.websiteDataStore
                ?? WKWebsiteDataStore.default()
            let redirect = try await ExtensionAuthWindow.run(
                url: url, extensionID: context.uniqueIdentifier,
                dataStore: store,
                interactive: options["interactive"] as? Bool ?? true
            )
            return redirect.absoluteString
        case "identity.getProfileUserInfo":
            // No Google account is signed into Chord, as in Chrome without
            // one. The empty identity is the honest answer.
            return ["id": "", "email": ""]
        case "identity.removeCachedAuthToken", "identity.clearAllCachedAuthTokens":
            return nil
        case "identity.getAuthToken":
            throw Unsupported(
                what: "Google sign-in tokens aren't available; use launchWebAuthFlow"
            )
        case "clients.pages":
            return host?.extensionPages(
                spaceID: spaceID, identifier: context.uniqueIdentifier
            ) ?? []
        case "runtime.getContexts":
            return host?.runtimeContexts(context) ?? []
        case "userScripts.file":
            guard let host, let folder = host.extensionFolder(for: context)
            else { throw Unsupported(what: "Extension is not loaded") }
            let script = args.first as? [String: Any] ?? [:]
            return try ExtensionShimFiles.userScriptFile(script, in: folder)
        case "userScripts.list":
            guard let host, let folder = host.extensionFolder(for: context)
            else { return [] }
            return ExtensionShimFiles.userScripts(in: folder)
        case "userScripts.save":
            guard let host, let folder = host.extensionFolder(for: context)
            else { throw Unsupported(what: "Extension is not loaded") }
            let scripts = args.first as? [[String: Any]] ?? []
            try ExtensionShimFiles.saveUserScripts(scripts, in: folder)
            return nil
        case "userScripts.worlds":
            guard let host, let folder = host.extensionFolder(for: context)
            else { return [] }
            return ExtensionShimFiles.worlds(in: folder)
        case "userScripts.world":
            guard let host, let folder = host.extensionFolder(for: context)
            else { throw Unsupported(what: "Extension is not loaded") }
            try ExtensionShimFiles.saveWorld(args.first as? [String: Any] ?? [:], in: folder)
            return nil
        case "scripting.file":
            guard let host,
                  let folder = host.extensionFolder(for: context)
            else { throw Unsupported(what: "Extension is not loaded") }
            return try ExtensionShimFiles.scriptingFile(
                args.first as? String ?? "",
                arguments: args.dropFirst().first as? [Any] ?? [],
                in: folder
            )
        case "permissions.granted":
            return grantedPermissions(context) + (host?.shimGranted(context) ?? [])
        case "permissions.request", "permissions.afterClick":
            let names = (args.first as? [String]) ?? []
            guard let host else { return false }
            return await host.requestShimPermissions(names, context: context)
        case "permissions.remove":
            let names = (args.first as? [String]) ?? []
            host?.removeShimPermissions(names, context: context)
            return true
        case "permissions.removeWebsites":
            return true
        case "background.loadedBefore":
            return host?.wasLoadedBefore(context) ?? false
        case "background.observe":
            guard let host else { return 0 }
            let generation = args.first as? Int ?? 0
            let token = args.count > 1 ? args[1] as? String ?? "" : ""
            return await host.observeWorker(
                context, generation: generation, token: token
            )
        case "background.unobserve":
            if let token = args.first as? String {
                host?.cancelWorkerObservation(context, token: token)
            }
            return nil
        case "background.wake":
            if let error = await host?.wakeBackground(context) {
                throw Unsupported(what: error.localizedDescription)
            }
            return nil
        case "background.revive":
            host?.reviveForShim(context)
            return nil
        case "tabs.describe":
            return host?.tabDescriptions(for: args.first, spaceID: spaceID) ?? []
        case "tabs.private":
            return host?.tabPrivacy(for: args.first, spaceID: spaceID) ?? false
        case "tabs.groups":
            return host?.tabGroups(for: args.first, spaceID: spaceID) ?? []
        case "tabs.activate":
            host?.activateTab(for: args.first, spaceID: spaceID)
            return nil
        case "tabs.move":
            guard let index = args.dropFirst().first as? Int else {
                throw Unsupported(what: "No destination for the tab")
            }
            host?.moveTab(for: args.first, to: index, spaceID: spaceID)
            return nil
        case "tabs.discard":
            return nil
        case "action.popup":
            // Chord uses WebKit's own action popover; the path is not needed.
            return nil
        case "debug.error":
            Log.extensions.error("extension shim: \(args.first as? String ?? "?")")
            return nil
        case "memory.rulesBuilt":
            return nil
        case "notifications.create":
            let named = args.first as? String
            let options = (named == nil ? args.first : args.dropFirst().first)
                as? [String: Any] ?? [:]
            let key = named ?? UUID().uuidString
            let center = UNUserNotificationCenter.current()
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            let content = UNMutableNotificationContent()
            content.title = options["title"] as? String ?? "Chord extension"
            content.body = options["message"] as? String ?? ""
            try? await center.add(UNNotificationRequest(
                identifier: "\(context.uniqueIdentifier).\(key)",
                content: content, trigger: nil
            ))
            return key
        case "notifications.clear":
            if let key = args.first as? String {
                UNUserNotificationCenter.current().removeDeliveredNotifications(
                    withIdentifiers: ["\(context.uniqueIdentifier).\(key)"]
                )
            }
            return true
        case "notifications.getAll":
            return [String: Any]()
        case "notifications.getPermissionLevel":
            return "granted"
        case "notifications.update":
            return false
        case "tts.speak":
            let options = (args.count > 1 ? args[1] : nil) as? [String: Any] ?? [:]
            if !(options["enqueue"] as? Bool ?? false) { speaker.stopSpeaking(at: .immediate) }
            let utterance = AVSpeechUtterance(string: args.first as? String ?? "")
            if let rate = options["rate"] as? Double {
                utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(rate)
            }
            speaker.speak(utterance)
            return nil
        case "tts.stop":
            speaker.stopSpeaking(at: .immediate)
            return nil
        case "tts.pause":
            speaker.pauseSpeaking(at: .immediate)
            return nil
        case "tts.resume":
            speaker.continueSpeaking()
            return nil
        case "tts.isSpeaking":
            return speaker.isSpeaking
        case "tts.getVoices":
            return AVSpeechSynthesisVoice.speechVoices().map {
                ["voiceName": $0.name, "lang": $0.language,
                 "remote": false, "eventTypes": ["start", "end"]]
            }
        case "management.getSelf", "management.get":
            let found = context.webExtension
            return ["id": context.uniqueIdentifier,
                    "name": found.displayName ?? "",
                    "shortName": found.displayShortName ?? "",
                    "version": found.version ?? "",
                    "description": found.displayDescription ?? "",
                    "enabled": true, "type": "extension",
                    "installType": "development", "mayDisable": true,
                    "offlineEnabled": true, "isApp": false,
                    "hostPermissions": [], "permissions": []]
        case "management.getAll":
            return []
        case "management.setEnabled", "management.uninstallSelf":
            throw Unsupported(what: "Extensions are enabled in Settings › Extensions")
        case "fontSettings.getFontList":
            return NSFontManager.shared.availableFontFamilies.map {
                ["fontId": $0, "displayName": $0]
            }
        case "fontSettings.getFont", "fontSettings.getDefaultFixedFontSize",
             "fontSettings.getMinimumFontSize":
            return ["fontId": "", "levelOfControl": "not_controllable"]
        case _ where api.hasPrefix("fontSettings.set") || api.hasPrefix("fontSettings.clear"):
            return nil
        case _ where api.hasPrefix("setting."):
            // chrome.privacy (and any other ChromeSetting): only an extension
            // that asked for the family a setting's name starts with may read
            // or change it, as in Chrome.
            let name = api.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            let family = String(name.prefix { $0 != "." })
            guard !family.isEmpty, declared(family, in: context) else {
                throw Unsupported(what: "The extension never asked for “\(family)”")
            }
            return ExtensionSettings.answer(
                api, args.first as? [String: Any] ?? [:],
                identifier: context.uniqueIdentifier, spaceID: spaceID
            )
        case "idle.queryState":
            return "active"
        case "idle.getAutoLockDelay":
            return 0
        case "power.requestKeepAwake", "power.releaseKeepAwake",
             "power.reportActivity":
            return api == "power.requestKeepAwake" ? true : nil
        case "system.cpu.getInfo":
            return ["archName": "arm64", "numOfProcessors": ProcessInfo.processInfo.processorCount,
                    "processors": []]
        case "system.memory.getInfo":
            return ["capacity": ProcessInfo.processInfo.physicalMemory,
                    "availableCapacity": 0]
        case "system.display.getInfo":
            return NSScreen.screens.enumerated().map { index, screen in
                ["id": "\(index)", "name": screen.localizedName,
                 "isActive": true, "isPrimary": index == 0,
                 "rotation": 0, "bounds": ["left": 0, "top": 0,
                                           "width": Int(screen.frame.width),
                                           "height": Int(screen.frame.height)]]
            }
        case "i18n.detectLanguage":
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(args.first as? String ?? "")
            let guesses = recognizer.languageHypotheses(withMaximum: 3)
            return ["isReliable": (guesses.values.max() ?? 0) > 0.6,
                    "languages": guesses.sorted { $0.value > $1.value }.map {
                        ["language": $0.key.rawValue, "percentage": Int($0.value * 100)]
                    }]
        default:
            if let permission = shimPermission(for: api), !declared(permission, in: context) {
                throw Unsupported(
                    what: "The extension never asked for “\(permission)”"
                )
            }
            if let data = host?.shimData {
                return try await data.answer(
                    api, args: args,
                    context: ExtensionShimContext(
                        identifier: context.uniqueIdentifier, spaceID: spaceID,
                        slug: host?.shimSlug(for: context) ?? ""
                    )
                )
            }
            throw Unsupported(what: "\(api) isn't available in Chord yet")
        }
    }

    /// The manifest permission Chrome requires for a Store-answered namespace.
    /// A nil answer means the API has no separate permission (or is handled
    /// above with its own gate).
    private static func shimPermission(for api: String) -> String? {
        switch api.split(separator: ".").first.map(String.init) {
        case "bookmarks": return "bookmarks"
        case "history": return "history"
        case "downloads": return "downloads"
        case "readingList": return "readingList"
        case "tabGroups": return "tabGroups"
        case "sidePanel": return "sidePanel"
        case "sessions": return "sessions"
        case "topSites": return "topSites"
        case "browsingData": return "browsingData"
        case "search": return "search"
        case "privacy": return "privacy"
        case "contentSettings": return "contentSettings"
        default: return nil
        }
    }

    struct Unsupported: LocalizedError {
        let what: String
        var errorDescription: String? { what }
    }

    /// A Chrome API permission the extension's own manifest names. Chord's
    /// added `nativeMessaging` never makes an extension eligible for another
    /// API; only the package's own declaration does.
    private static func declared(
        _ permission: String, in context: WKWebExtensionContext
    ) -> Bool {
        let manifest = context.webExtension.manifest
        let required = manifest["permissions"] as? [Any] ?? []
        let optional = manifest["optional_permissions"] as? [Any] ?? []
        return (required + optional).contains { ($0 as? String) == permission }
    }

    private static func grantedPermissions(
        _ context: WKWebExtensionContext
    ) -> [String] {
        let manifest = context.webExtension.manifest
        return ((manifest["permissions"] as? [Any] ?? [])
            + (manifest["optional_permissions"] as? [Any] ?? []))
            .compactMap { $0 as? String }
    }
}

/// File-writing half of `chrome.scripting` and `chrome.userScripts`.
enum ExtensionShimFiles {
    static func scriptingFile(
        _ function: String, arguments: [Any], in folder: URL
    ) throws -> String {
        guard !function.isEmpty, function.utf8.count <= 1_000_000,
              JSONSerialization.isValidJSONObject(arguments),
              let data = try? JSONSerialization.data(withJSONObject: arguments),
              let encoded = String(data: data, encoding: .utf8)
        else { throw ExtensionShimBroker.Unsupported(what: "Invalid script function or arguments") }
        let source = "(\(function))(...\(encoded))\n"
        let name = "script-" + SHA256.hash(data: Data(source.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined() + ".js"
        let dir = folder.appending(path: "_chord", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: name)
        if !FileManager.default.fileExists(atPath: url.path) {
            try source.write(to: url, atomically: true, encoding: .utf8)
        }
        return "_chord/" + name
    }


    /// A user script as a file WebKit can inject. Globs are checked in the
    /// page, and USER_SCRIPT messages are tagged so the worker can route them.
    static func userScriptFile(
        _ script: [String: Any], in folder: URL
    ) throws -> String {
        let json = { (value: Any) in
            (try? JSONSerialization.data(withJSONObject: value))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        }
        var code = ""
        for source in script["js"] as? [[String: Any]] ?? [] {
            if let inline = source["code"] as? String {
                code += inline + "\n;\n"
            } else if let file = source["file"] as? String,
                      let path = inside(file, of: folder),
                      let text = try? String(contentsOf: path, encoding: .utf8) {
                code += text + "\n;\n"
            }
        }
        let userWorld = (script["world"] as? String) != "MAIN"
        let prelude = #"""
          const chrome = (() => {
            const runtime = globalThis.chrome.runtime;
            return { runtime: {
              id: runtime.id, getURL: (path) => runtime.getURL(path),
              get lastError() { return runtime.lastError; },
              sendMessage: (message, ...rest) => runtime.sendMessage(
                { __chordUserScript: true, message },
                ...rest.filter((r) => typeof r === "function" || (r && typeof r === "object"))
              ),
              connect: (info) => runtime.connect({
                ...(info || {}), name: "chord-us:" + ((info && info.name) || "")
              }),
            } };
          })();
          const browser = chrome;
        """#
        let text = #"""
        /* Chord: a user script (chrome.userScripts) */
        chord_user_script: {
          const __chordHref = location.href;
          const __chordGlob = (g) => new RegExp(
            "^" + g.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*").replace(/\?/g, ".") + "$"
          );
          const __chordIn = \#(json(script["includeGlobs"] ?? [])), __chordOut = \#(json(script["excludeGlobs"] ?? []));
          if ((__chordIn.length && !__chordIn.some((g) => __chordGlob(g).test(__chordHref)))
              || __chordOut.some((g) => __chordGlob(g).test(__chordHref))) break chord_user_script;
        \#(userWorld ? prelude : "")
        \#(code)
        }
        """#
        let name = "us-" + SHA256.hash(data: Data(text.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined() + ".js"
        let dir = folder.appending(path: "_chord", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: name)
        if !FileManager.default.fileExists(atPath: url.path) {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return "_chord/" + name
    }

    static func userScripts(in folder: URL) -> [[String: Any]] {
        let url = folder.appending(path: "_chord/userscripts.json")
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return list
    }

    static func saveUserScripts(_ scripts: [[String: Any]], in folder: URL) throws {
        let dir = folder.appending(path: "_chord", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: scripts)
        try data.write(to: dir.appending(path: "userscripts.json"), options: .atomic)
        // Files no saved script is written in any more, once a moment has
        // passed. A script injected right now is left alone.
        let keep = Set(scripts.compactMap { try? userScriptFile($0, in: folder) }
            .map { URL(fileURLWithPath: $0).lastPathComponent })
        for file in (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? [] where file.lastPathComponent.hasPrefix("us-")
            && !keep.contains(file.lastPathComponent) {
            let age = (try? file.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate).map { -$0.timeIntervalSinceNow } ?? 999
            if age > 60 { try? FileManager.default.removeItem(at: file) }
        }
    }

    static func worlds(in folder: URL) -> [[String: Any]] {
        let url = folder.appending(path: "_chord/worlds.json")
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return list
    }

    static func saveWorld(_ props: [String: Any], in folder: URL) throws {
        let dir = folder.appending(path: "_chord", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var list = worlds(in: folder)
        let id = props["worldId"] as? String ?? ""
        list.removeAll { ($0["worldId"] as? String ?? "") == id }
        if props["reset"] as? Bool != true { list.append(props) }
        let data = try JSONSerialization.data(withJSONObject: list)
        try data.write(to: dir.appending(path: "worlds.json"), options: .atomic)
    }

    private static func inside(_ name: String, of folder: URL) -> URL? {
        let root = folder.standardizedFileURL
        let path = root.appendingPathComponent(
            name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        ).standardizedFileURL
        guard path.path.hasPrefix(root.path + "/"),
              (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              path.resolvingSymlinksInPath().path.hasPrefix(
                root.resolvingSymlinksInPath().path + "/"
              )
        else { return nil }
        return path
    }

}

/// chrome.privacy's settings: what each extension set, per Space, kept across
/// launches as Chrome keeps it. Ported from Search.
///
/// A get always answers a ChromeSetting, `{ value, levelOfControl }`, never
/// nothing: Bitwarden's popup reads `levelOfControl` off the answer to
/// `passwordSavingEnabled.get`, and threw on every open while it was missing.
enum ExtensionSettings {
    static func key(identifier: String, spaceID: UUID) -> String {
        "chord.extensions.settings.\(spaceID).\(identifier)"
    }

    static func answer(
        _ api: String, _ details: [String: Any], identifier: String, spaceID: UUID
    ) -> Any? {
        let parts = api.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let name = parts[1]
        let key = key(identifier: identifier, spaceID: spaceID)
        var mine = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        switch parts[0] {
        case "setting.set":
            mine[name] = details["value"]
        case "setting.clear":
            mine[name] = nil
        default:
            let value = mine[name] ?? defaultValue(name)
            return [
                "value": value ?? NSNull(),
                "levelOfControl": mine[name] != nil
                    ? "controlled_by_this_extension" : "controllable_by_this_extension",
            ]
        }
        if mine.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(mine, forKey: key)
        }
        return nil
    }

    /// Chrome's own defaults, the privacy-preserving ones off.
    private static func defaultValue(_ name: String) -> Any? {
        switch name {
        case "privacy.network.webRTCIPHandlingPolicy": return "default"
        case "privacy.websites.doNotTrackEnabled", "privacy.websites.adMeasurementEnabled",
             "privacy.websites.fledgeEnabled", "privacy.websites.topicsEnabled",
             "privacy.services.safeBrowsingExtendedReportingEnabled": return false
        default: return true
        }
    }
}
