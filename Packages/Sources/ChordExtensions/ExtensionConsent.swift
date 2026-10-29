import AppKit
import Foundation
import WebKit

/// One install (or update) question: what the user is asked before an
/// extension is added, or before an update that asks for more replaces it.
/// WebKit-free, so the service in ChordStore can hand it to whoever asks.
public struct ExtensionConsentQuestion: Sendable {
    public let name: String
    /// What it will be able to do, in words.
    public let wants: [String]
    /// The bundle, for its icon.
    public let bundleURL: URL
    /// An update whose permissions grew: Return keeps the old version.
    public let updating: Bool
}

/// What an extension asks for, as the user is told it and as it is written
/// down at install. Ported from Search's `describe`, `grants` and `ask`.
@MainActor
public enum ExtensionConsent {
    /// Chrome APIs Chord's shim answers itself, which WebKit's permission list
    /// doesn't name.
    private static let shimAnswered: [(String, String)] = [
        ("userScripts", "Run scripts you add to it on websites"),
        ("history", "Read and change your history"),
        ("bookmarks", "Read and change your bookmarks"),
        ("downloads", "Manage your downloads"),
        ("privacy", "Change your privacy settings"),
        ("browsingData", "Clear your browsing data"),
        ("management", "See your other extensions"),
        ("notifications", "Show notifications"),
        ("sessions", "See your recently closed tabs"),
        ("topSites", "See your most visited sites"),
        ("identity", "Sign you in to its service"),
        ("desktopCapture", "Record your screen or a window, when you choose what to share"),
        ("tabCapture", "Record a tab, when you ask it to"),
    ]

    private static let words: [(WKWebExtension.Permission, String)] = [
        (.tabs, "See your open tabs and their addresses"),
        (.cookies, "Read and change cookies"),
        (.webNavigation, "See where you go"),
        (.webRequest, "See the requests pages make"),
        (.declarativeNetRequest, "Block or change requests pages make"),
        (.clipboardWrite, "Write to the clipboard"),
        (.nativeMessaging, "Talk to apps on this Mac"),
        (.scripting, "Run scripts in pages"),
    ]

    /// What it was allowed, as written down and compared on every update:
    /// WebKit's permissions, the sites it reaches, and the APIs the shim
    /// answers. Leaves out what Chord itself added to the manifest.
    public static func grants(of bundle: URL) async -> [String] {
        guard let found = try? await WKWebExtension(resourceBaseURL: bundle) else { return [] }
        let added = addedByChord(bundle)
        let declared = declaredPermissions(bundle)
        var out = Set(found.requestedPermissions.map(\.rawValue).filter { !added.contains($0) })
        out.formUnion(found.allRequestedMatchPatterns.map { "site:" + $0.string })
        let shimNames = Set(shimAnswered.map(\.0))
        out.formUnion(declared.filter { shimNames.contains($0) && !added.contains($0) }.map { "chord:" + $0 })
        return out.sorted()
    }

    /// The question to ask before installing (or updating to) this bundle.
    public static func question(
        for bundle: URL, name: String, updating: Bool = false
    ) async -> ExtensionConsentQuestion {
        ExtensionConsentQuestion(
            name: name, wants: await describe(bundle), bundleURL: bundle, updating: updating
        )
    }

    /// What it wants, in words.
    static func describe(_ bundle: URL) async -> [String] {
        guard let found = try? await WKWebExtension(resourceBaseURL: bundle) else { return [] }
        var out: [String] = []
        let added = addedByChord(bundle)
        let declared = declaredPermissions(bundle)
        let patterns = found.allRequestedMatchPatterns.filter { !ExtensionGrants.withheld($0) }
        if patterns.contains(where: { $0.matchesAllHosts || $0.matchesAllURLs }) {
            out.append("Read and change everything on every website")
        } else if !patterns.isEmpty {
            let hosts = Array(Set(patterns.compactMap(\.host).filter { !$0.isEmpty })).sorted()
            out.append(
                "Read and change what's on " + hosts.prefix(4).joined(separator: ", ")
                    + (hosts.count > 4 ? " and \(hosts.count - 4) more" : "")
            )
        }
        for (permission, sentence) in words
        where found.requestedPermissions.contains(permission) && !added.contains(permission.rawValue) {
            out.append(sentence)
        }
        for (name, sentence) in shimAnswered where declared.contains(name) && !added.contains(name) {
            out.append(sentence)
        }
        return out
    }

    private static func addedByChord(_ bundle: URL) -> Set<String> {
        let data = try? Data(contentsOf: bundle.appending(path: ExtensionShims.added))
        return Set((data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String]) ?? [])
    }

    private static func declaredPermissions(_ bundle: URL) -> Set<String> {
        Set(((try? ExtensionBundle.manifest(at: bundle))?["permissions"] as? [String]) ?? [])
    }

    // MARK: - Asking

    /// The last question asked, so the next waits for its answer.
    private static var lastQuestion: Task<Bool, Never>?

    /// Asks, one question at a time, as a sheet on the browser window. An
    /// app-modal alert would stop every page, download and extension for as
    /// long as it waits. Only with no window at all is it app-modal, and an
    /// update is then refused rather than asked.
    public static func ask(_ question: ExtensionConsentQuestion) async -> Bool {
        let before = lastQuestion
        let task = Task { @MainActor () -> Bool in
            _ = await before?.value
            let alert = NSAlert()
            alert.messageText = question.updating
                ? "“\(question.name)” wants more access to update"
                : "Add “\(question.name)” to Chord?"
            let list = question.wants.isEmpty
                ? "It doesn't ask for anything special."
                : "It will be able to:\n• " + question.wants.joined(separator: "\n• ")
            alert.informativeText = question.updating
                ? list + "\n\nNot updating keeps the version you have."
                : list
            if let found = try? await WKWebExtension(resourceBaseURL: question.bundleURL),
                let icon = found.icon(for: CGSize(width: 64, height: 64))
            {
                alert.icon = icon
            }
            let confirm = alert.addButton(withTitle: question.updating ? "Update" : "Add Extension")
            let cancel = alert.addButton(withTitle: question.updating ? "Don't Update" : "Cancel")
            if question.updating {
                // More access is the thing to stop and read: Return refuses.
                confirm.keyEquivalent = ""
                cancel.keyEquivalent = "\r"
            }
            guard let window = NSApp.mainWindow
                ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain })
            else {
                guard !question.updating else { return false }
                return alert.runModal() == .alertFirstButtonReturn
            }
            return await withCheckedContinuation { done in
                alert.beginSheetModal(for: window) {
                    done.resume(returning: $0 == .alertFirstButtonReturn)
                }
            }
        }
        lastQuestion = task
        return await task.value
    }
}
