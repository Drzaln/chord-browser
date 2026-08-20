import ChordCore
import ChordExtensions
import ChordStore
import SwiftUI

/// The grant/deny sheet for an extension permission prompt (M7, 7.5c).
///
/// All-or-nothing per request, which is how browsers present these and what the
/// host expects back. Denying (button or dismiss) returns an empty allowed set,
/// so content scripts and host access simply stay inert rather than erroring.
struct ExtensionPermissionSheet: View {
    let request: PermissionRequest
    @Bindable var store: TabStore

    private var name: String { request.displayName ?? request.slug }

    private var prompt: String {
        switch request.kind {
        case .matchPattern: "“\(name)” wants to read and change your data on:"
        case .url: "“\(name)” wants to access:"
        case .permission: "“\(name)” wants to use these features:"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                Text(prompt)
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(request.items, id: \.self) { item in
                        Text(item)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 120)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

            HStack {
                Spacer()
                Button("Don’t Allow") { resolve(allow: false) }
                    .keyboardShortcut(.cancelAction)
                Button("Allow") { resolve(allow: true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func resolve(allow: Bool) {
        store.resolvePermissionRequest(request.id, allow: allow)
    }
}
