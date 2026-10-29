import Foundation
import Testing
import WebKit

@testable import ChordExtensions

/// M8: the native-messaging host lookup and the shim's in-process endpoint.
@MainActor
struct ExtensionNativeTests {
    private let id = String(repeating: "a", count: 32)

    private func folder(manifest: [String: Any]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "chord-native-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: manifest)
        try data.write(to: dir.appending(path: "com.example.host.json"))
        return dir
    }

    @Test func hostMustAllowTheExtensionID() throws {
        let dir = try folder(manifest: [
            "name": "com.example.host",
            "path": "/bin/echo",
            "allowed_origins": ["chrome-extension://\(id)/"],
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let program = try ExtensionNative.host(
            named: "com.example.host", in: [dir], extensionID: id
        )
        #expect(program.path == "/bin/echo")
    }

    @Test func hostForAnotherExtensionIsRefused() throws {
        let dir = try folder(manifest: [
            "name": "com.example.host",
            "path": "/bin/echo",
            "allowed_origins": ["chrome-extension://\(String(repeating: "b", count: 32))/"],
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(throws: ExtensionNative.Refused.self) {
            try ExtensionNative.host(named: "com.example.host", in: [dir], extensionID: id)
        }
    }

    @Test func nonExecutableHostIsRefused() throws {
        let dir = try folder(manifest: [
            "name": "com.example.host",
            "path": "/etc/hosts",
            "allowed_origins": ["chrome-extension://\(id)/"],
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(throws: ExtensionNative.Refused.self) {
            try ExtensionNative.host(named: "com.example.host", in: [dir], extensionID: id)
        }
    }

    @Test func invalidHostNameIsRefused() throws {
        #expect(throws: ExtensionNative.Refused.self) {
            try ExtensionNative.host(named: "../escape", in: [], extensionID: id)
        }
    }

    /// The shim holds what a worker posts on a native port until the browser
    /// says the port has arrived. Left unanswered and passed to the host, the
    /// question cost Bitwarden's biometric unlock some ten seconds.
    @Test func theShimsWordsAreTheBrowsersNotTheHosts() {
        #expect(ExtensionNative.shimWord(in: ["__chordNative": "here?"]) == .asked)
        #expect(ExtensionNative.shimWord(in: ["__chordNative": "beat"]) == .other)
        #expect(ExtensionNative.shimWord(
            in: ["appId": "x", "message": ["command": "setupEncryption"]]
        ) == nil)
        #expect(ExtensionNative.shimWord(in: "here?") == nil)
    }

    @Test func framedNativeMessageRoundTrips() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "chord-native-pipe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appending(path: "host.py")
        try """
            #!/usr/bin/env python3
            import json, struct, sys
            raw = sys.stdin.buffer.read(4)
            size = struct.unpack('<I', raw)[0]
            message = json.loads(sys.stdin.buffer.read(size))
            reply = json.dumps({"echo": message}).encode()
            sys.stdout.buffer.write(struct.pack('<I', len(reply)) + reply)
            sys.stdout.buffer.flush()
            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path
        )

        let direct = HostPipe(program: script, origin: "chrome-extension://\(id)/")
        try direct.start()
        defer { direct.stop() }
        let reply = try await direct.request(Data(#"{"hello":"world"}"#.utf8))
        let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any]
        let echo = object?["echo"] as? [String: Any]
        #expect(echo?["hello"] as? String == "world")
    }
}

@MainActor
struct ExtensionShimBrokerTests {
    private func context(offscreen: Bool = true) async throws -> WKWebExtensionContext {
        WKWebExtension.MatchPattern.registerCustomURLScheme("chrome-extension")
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "chord-shim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = """
            { "manifest_version": 3, "name": "Shim Test", "version": "1.0",
              "permissions": [\(offscreen ? #""offscreen""# : "")] }
            """
        try manifest.write(to: dir.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        let extensionBundle = try await WKWebExtension(resourceBaseURL: dir)
        let context = WKWebExtensionContext(for: extensionBundle)
        context.uniqueIdentifier = String(repeating: "a", count: 32)
        context.baseURL = try #require(URL(string: "chrome-extension://\(context.uniqueIdentifier)/"))
        return context
    }

    @Test func unknownAPIIsAnErrorNotACrash() async throws {
        let context = try await context()
        let reply = try await ExtensionShimBroker.answer(
            ["api": "not.a.real.api", "args": []],
            context: context,
            spaceID: UUID()
        )
        #expect((reply as? [String: Any])?["error"] is String)
    }

    @Test func offscreenHasDocumentStartsFalse() async throws {
        let context = try await context()
        let reply = try await ExtensionShimBroker.answer(
            ["api": "offscreen.hasDocument", "args": []],
            context: context,
            spaceID: UUID()
        )
        #expect((reply as? [String: Any])?["value"] as? Bool == false)
    }

    @Test func offscreenRequiresItsDeclaredPermission() async throws {
        let context = try await context(offscreen: false)
        let reply = try await ExtensionShimBroker.answer(
            ["api": "offscreen.hasDocument", "args": []],
            context: context,
            spaceID: UUID()
        )
        let error = (reply as? [String: Any])?["error"] as? String
        #expect(error?.contains("offscreen") == true)
    }

    @Test func shimAddedNativeMessagingDoesNotGrantHostAccess() async throws {
        WKWebExtension.MatchPattern.registerCustomURLScheme("chrome-extension")
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "chord-native-perm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
            { "manifest_version": 3, "name": "No Native", "version": "1.0" }
            """.write(
                to: dir.appending(path: "manifest.json"), atomically: true, encoding: .utf8
            )
        try ExtensionShims.prepare(dir, fresh: true)
        let web = try await WKWebExtension(resourceBaseURL: dir)
        let context = WKWebExtensionContext(for: web)
        #expect(!ExtensionShims.asksForNative(in: dir, context: context))

        let asked = dir.appending(path: "asked")
        try FileManager.default.createDirectory(at: asked, withIntermediateDirectories: true)
        try """
            { "manifest_version": 3, "name": "Asks Native", "version": "1.0",
              "permissions": ["nativeMessaging"] }
            """.write(
                to: asked.appending(path: "manifest.json"), atomically: true, encoding: .utf8
            )
        try ExtensionShims.prepare(asked, fresh: true)
        let askedWeb = try await WKWebExtension(resourceBaseURL: asked)
        let askedContext = WKWebExtensionContext(for: askedWeb)
        #expect(ExtensionShims.asksForNative(in: asked, context: askedContext))
    }

    @Test func offscreenRequiresAnExtensionPage() async throws {
        let context = try await context()
        let reply = try await ExtensionShimBroker.answer(
            ["api": "offscreen.createDocument",
             "args": [["url": "https://example.com/", "reasons": ["DOM_PARSER"]]]],
            context: context,
            spaceID: UUID()
        )
        #expect((reply as? [String: Any])?["error"] is String)
    }
}
