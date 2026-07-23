#if DEBUG
import BrowserStore
import SwiftUI

/// Live web view count, footprint, and frame time (6.7). Debug builds only —
/// the whole file compiles out of release.
struct DebugOverlay: View {
    let store: TabStore

    @State private var isVisible = false
    @State private var footprintMB: Double = 0
    @State private var liveViews = 0
    @State private var frameMilliseconds: Double = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear

            if isVisible {
                VStack(alignment: .leading, spacing: 2) {
                    row("live web views", "\(liveViews)")
                    row("footprint", String(format: "%.0f MB", footprintMB))
                    row("main frame", String(format: "%.1f ms", frameMilliseconds))
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
