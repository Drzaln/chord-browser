import ChordCore
import ChordStore
import SwiftUI

/// The grant/deny sheet for a camera/microphone or notification request
/// (non-spec: user-requested). All-or-nothing per request, matching how browsers
/// present these; dismissing without a choice is treated as a denial by
/// `RootSheets`.
struct SitePermissionSheet: View {
    let prompt: SitePermissionPrompt
    @Bindable var store: TabStore

    private var isNotification: Bool { prompt.kinds == [.notification] }

    private var message: String {
        if isNotification {
            return "“\(prompt.host)” wants to send you notifications."
        }
        let list = prompt.kinds.map(\.label).joined(separator: " and ")
        return "“\(prompt.host)” wants to use your \(list)."
    }

    private var icon: String {
        if isNotification { return "bell.fill" }
        if prompt.kinds.contains(.geolocation) { return "location.fill" }
        return prompt.kinds.contains(.camera) ? "video.fill" : "mic.fill"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Don’t Allow") { store.resolveSitePermission(prompt.id, allow: false) }
                    .keyboardShortcut(.cancelAction)
                Button("Allow") { store.resolveSitePermission(prompt.id, allow: true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
