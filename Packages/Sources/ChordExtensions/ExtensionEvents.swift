import Foundation
import WebKit

/// What the browser tells a worker without being asked (c1k.5).
///
/// The shim used to ask for tab groups every 3 seconds, for ever, in every
/// worker that listened. Now a worker opens this port at its first
/// chrome.tabGroups listener, and hears `{ chordEvent: "tabGroups" }` when
/// folders change; it then asks once and tells its listeners what changed.
@MainActor
enum ExtensionEvents {
    static let name = ExtensionShims.application + ".events"

    private static var ports: [ObjectIdentifier: WKWebExtension.MessagePort] = [:]

    static func connect(_ port: WKWebExtension.MessagePort) {
        let key = ObjectIdentifier(port)
        ports[key] = port
        // Nothing comes the other way.
        port.messageHandler = { _, _ in }
        port.disconnectHandler = { _ in
            MainActor.assumeIsolated { _ = ports.removeValue(forKey: key) }
        }
    }

    static func post(_ event: String) {
        for (key, port) in ports {
            if port.isDisconnected {
                ports[key] = nil
                continue
            }
            port.sendMessage(["chordEvent": event], completionHandler: nil)
        }
    }

    static var listening: Int { ports.values.filter { !$0.isDisconnected }.count }

    static func reset() {
        for port in ports.values { port.disconnect() }
        ports = [:]
    }
}
