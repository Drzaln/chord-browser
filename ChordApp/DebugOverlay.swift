#if DEBUG
import ChordStore
import SwiftUI

/// Live web view count, footprint, and frame time (6.7). Debug builds only —
/// the whole file compiles out of release.
struct DebugOverlay: View {
    let store: TabStore
    /// This window's state, so a multi-window session can be told apart on
    /// screen: which window this is, what Space it is in, and what it selected.
    let windowState: WindowState

    @State private var isVisible = false
    @State private var footprintMB: Double = 0
    @State private var liveViews = 0
    @State private var frameMilliseconds: Double = 0
    /// Codec support for the active pane (AV1/VP9/HEVC/H.264) — why Reels/Shorts
    /// look soft while YouTube stays crisp. Probed on show and on tab change, not
    /// every poll: it is a property of the WebKit build, not the moment.
    @State private var codecs: [(label: String, supported: Bool, hardware: Bool)] = []
    @State private var probedTabID: UUID?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear

            if isVisible {
                VStack(alignment: .leading, spacing: 2) {
                    row("window", windowIdentity)
                    row("space", short(windowState.activeSpaceID))
                    row("selected tab", short(windowState.selectedTabID))
                    row("windows open", "\(store.windows.count)")
                    row("also showing it", "\(othersShowingSelection)")
                    row("live web views", "\(liveViews)")
                    row("footprint", String(format: "%.0f MB", footprintMB))
                    row("main frame", String(format: "%.1f ms", frameMilliseconds))
                    if !codecs.isEmpty {
                        Divider().padding(.vertical, 1)
                        ForEach(codecs, id: \.label) { codec in
                            row("codec \(codec.label)", codecValue(codec))
                        }
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .padding(8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                .padding(12)
                .allowsHitTesting(false)
                .task { await sample() }
            }
        }
        .background {
            // Hidden hotkey host, so the overlay costs nothing when hidden.
            Button("") { isVisible.toggle() }
                .keyboardShortcut("p", modifiers: [.command, .control])
                .opacity(0)
        }
    }

    /// `primary` or `secondary#n`, plus the object's address, so two windows are
    /// never confused for one.
    private var windowIdentity: String {
        let index = store.windows.firstIndex { $0 === windowState }
        let role = windowState === store.primaryWindow ? "primary" : "secondary"
        let address = String(UInt(bitPattern: ObjectIdentifier(windowState).hashValue) % 0xFFFF, radix: 16)
        return "\(role)[\(index.map(String.init) ?? "?")] \(address)"
    }

    /// How many *other* windows have this window's selected tab on screen. Above
    /// zero means two windows are competing for one web view, which AppKit
    /// cannot satisfy — a view has one superview.
    private var othersShowingSelection: Int {
        guard let selected = windowState.selectedTabID else { return 0 }
        return store.windows.filter { $0 !== windowState && $0.selectedTabID == selected }.count
    }

    private func short(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        return String(id.uuidString.prefix(8))
    }

    /// "no" when unsupported, "hw" when hardware (power-efficient) decode — what
    /// sites gate AV1 on — else "sw" for software-only.
    private func codecValue(_ codec: (label: String, supported: Bool, hardware: Bool)) -> String {
        guard codec.supported else { return "no" }
        return codec.hardware ? "hw" : "sw"
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
        }
        .frame(width: 150, alignment: .leading)
    }

    /// Polls only while the overlay is on screen, so it cannot contribute to
    /// idle CPU in normal use.
    private func sample() async {
        while !Task.isCancelled && isVisible {
            let start = CFAbsoluteTimeGetCurrent()
            liveViews = store.liveWebViewCount
            footprintMB = Diagnostics.footprintMB()
            frameMilliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1000

            // Re-probe codecs only when the active tab changed — the answer is
            // fixed per WebKit build, and each probe is four JS round-trips.
            let selected = windowState.selectedTabID
            if selected != probedTabID {
                probedTabID = selected
                codecs = await store.activeCodecSupport(in: windowState) ?? []
            }

            try? await Task.sleep(for: .seconds(1))
        }
    }
}

enum Diagnostics {
    /// `phys_footprint` is what Instruments and jetsam actually judge us on —
    /// resident size understates the real cost.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }
}
#endif
