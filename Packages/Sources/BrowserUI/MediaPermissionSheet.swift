import BrowserCore
import BrowserStore
import SwiftUI

/// The grant/deny sheet for a camera/microphone request (non-spec:
/// user-requested). All-or-nothing per request, matching how browsers present
/// these; dismissing without a choice is treated as a denial by `RootSheets`.
struct MediaPermissionSheet: View {
    let request: MediaPermissionRequest
    @Bindable var store: TabStore

    private var deviceList: String {
        request.devices.map(\.label).joined(separator: " and ")
    }

    private var icon: String {
        request.devices.contains(.camera) ? "video.fill" : "mic.fill"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                Text("“\(request.host)” wants to use your \(deviceList).")
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Don’t Allow") { store.resolveMediaPermission(request.id, allow: false) }
                    .keyboardShortcut(.cancelAction)
                Button("Allow") { store.resolveMediaPermission(request.id, allow: true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
