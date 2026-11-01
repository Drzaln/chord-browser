import Foundation
import WebKit

/// Holds a worker that keeps being woken (c1k.9).
///
/// WebKit unloads an extension's worker after 30 seconds with nothing on a
/// port, and the next event starts it again in a new web process. Bitwarden
/// signed out has an alarm every minute, so each Space it was enabled in
/// launched a web process a minute: most of Chord's idle energy in the
/// 2026-10-30 baseline. Chrome restarts a worker inside a process that stays.
///
/// Every worker's shim opens this port as it starts. A worker that started
/// again soon after it last started or was let go is on a short cycle: the
/// port is held for `hold`, and every `beat` the worker gets an event (a ping
/// from one of the extension's own pages, see the host), which restarts
/// WebKit's idle clock; traffic on the port alone does not. Any other
/// worker's port is closed at once and it unloads as before.
///
/// A hold is renewed while the worker is still being woken: the shim says
/// "woke" on the port when an alarm or a message (not Chord's ping) reaches
/// it. Let go after one hold, Bitwarden started again within a minute, and
/// its start calls into every tab, waking every suspended tab process
/// (c1k.14).
@MainActor
enum ExtensionKeepAlive {
    static let name = ExtensionShims.application + ".keepalive"

    /// A start this soon after the last one (or a release) means the worker
    /// is being woken on a cycle.
    static var window: TimeInterval = 150
    /// How long one hold lasts. A worker still on its cycle after that starts
    /// within `window` and is held again.
    static var hold: TimeInterval = 600
    static var beat: TimeInterval = 20

    /// When each worker last started or was let go, by "<space>|<extension>".
    private static var lastAwake: [String: Date] = [:]
    /// When each held worker last said an event reached it.
    private static var lastWoken: [String: Date] = [:]
    /// The hold on each held worker; the token tells a hold from a later one.
    private static var held: [String: (token: UUID, task: Task<Void, Never>)] = [:]

    /// Whether a worker starting now is held.
    static func shouldHold(_ key: String, now: Date = Date()) -> Bool {
        defer { lastAwake[key] = now }
        guard held[key] == nil, let last = lastAwake[key] else { return false }
        return now.timeIntervalSince(last) < window
    }

    /// The shim says an event reached the held worker.
    static func noteWoken(_ key: String, now: Date = Date()) {
        lastWoken[key] = now
    }

    /// Whether a hold ending now goes on: the worker was woken within
    /// `window`, so let go it would only start again.
    static func shouldRenew(_ key: String, now: Date = Date()) -> Bool {
        guard let last = lastWoken[key] else { return false }
        return now.timeIntervalSince(last) < window
    }

    /// `ping` sends the worker an event; WebKit restarts a worker's idle
    /// clock on an event, not on a native port's traffic.
    static func connect(
        _ port: WKWebExtension.MessagePort, key: String,
        ping: @escaping @MainActor () async -> Void
    ) {
        guard shouldHold(key) else {
            port.disconnect()
            return
        }
        Log.extensions.notice("holding worker \(key): woken again within \(Int(window)) s")
        lastWoken[key] = nil
        // The shim's "beat" answers are the point, and nothing to act on;
        // "woke" says the worker still has a reason to be running.
        port.messageHandler = { message, _ in
            guard (message as? [String: Any])?["__chordNative"] as? String == "woke" else { return }
            MainActor.assumeIsolated { noteWoken(key) }
        }
        let token = UUID()
        let task = Task { @MainActor in
            let start = Date()
            var until = start.addingTimeInterval(hold)
            while !Task.isCancelled, !port.isDisconnected {
                if Date() >= until {
                    guard shouldRenew(key) else { break }
                    Log.extensions.notice("holding worker \(key) again: still being woken")
                    until = Date().addingTimeInterval(hold)
                }
                try? await Task.sleep(for: .seconds(beat))
                if Task.isCancelled || port.isDisconnected { break }
                await ping()
            }
            let closed = port.isDisconnected
            Log.extensions.notice(
                "let go of worker \(key) after \(Int(Date().timeIntervalSince(start))) s\(closed ? ", its port closed" : "")"
            )
            release(key, token: token)
            if !closed { port.disconnect() }
        }
        held[key] = (token, task)
        port.disconnectHandler = { _ in
            MainActor.assumeIsolated {
                held[key].map { if $0.token == token { $0.task.cancel() } }
            }
        }
    }

    private static func release(_ key: String, token: UUID) {
        guard held[key]?.token == token else { return }
        held[key] = nil
        lastAwake[key] = Date()
    }

    /// The extension is gone from the Space: forget its cycle.
    static func forget(_ key: String) {
        held.removeValue(forKey: key)?.task.cancel()
        lastAwake[key] = nil
        lastWoken[key] = nil
    }

    static func isHolding(_ key: String) -> Bool { held[key] != nil }
    static func hasSeen(_ key: String) -> Bool { lastAwake[key] != nil }

    static func reset() {
        for hold in held.values { hold.task.cancel() }
        held = [:]
        lastAwake = [:]
        lastWoken = [:]
    }
}
