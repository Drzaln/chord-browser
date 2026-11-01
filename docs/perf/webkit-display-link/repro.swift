// WebKit: a suspended hidden page leaves the UI process's display link firing.
// swiftc -O repro.swift -o repro && ./repro [suspend|none]
import AppKit
import Darwin
import WebKit

let policyArg = CommandLine.arguments.dropFirst().first ?? "suspend"
let policy: WKPreferences.InactiveSchedulingPolicy = policyArg == "none" ? .none : .suspend

func wakeups() -> UInt64 {
    var info = rusage_info_v4()
    let ok = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
    }
    return ok == 0 ? info.ri_interrupt_wkups + info.ri_pkg_idle_wkups : 0
}

final class App: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var views: [WKWebView] = []
    let start = Date()

    func applicationDidFinishLaunching(_ note: Notification) {
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
                          styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        for i in 0..<5 {
            let configuration = WKWebViewConfiguration()
            configuration.preferences.inactiveSchedulingPolicy = policy
            let web = WKWebView(frame: window.contentView!.bounds, configuration: configuration)
            web.autoresizingMask = [.width, .height]
            // Each page its own site, so its own web process.
            web.loadHTMLString("<!doctype html><h1>page \(i)</h1>", baseURL: URL(string: "https://site\(i).example/")!)
            // Page 0 is the one on screen; the others are "background tabs":
            // in the window, hidden.
            web.isHidden = i != 0
            window.contentView!.addSubview(web)
            views.append(web)
        }
        var last = wakeups()
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            let now = wakeups()
            print(String(format: "t=%3.0fs  UI wakeups/s %6.1f", Date().timeIntervalSince(self.start), Double(now - last) / 10))
            fflush(stdout)
            last = now
        }
        // Every 60 s, the window changes state, which WebKit passes to every
        // page in it, the hidden ones too: minimized and restored, then
        // deactivated and activated (as a user switching apps would).
        var round = 0
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            round += 1
            if round % 2 == 1 {
                print("        minimize + restore window")
                self.window.miniaturize(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.window.deminiaturize(nil) }
            } else {
                print("        deactivate + activate app")
                NSApp.hide(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    NSApp.unhide(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
        Timer.scheduledTimer(withTimeInterval: 395, repeats: false) { _ in NSApp.terminate(nil) }
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
