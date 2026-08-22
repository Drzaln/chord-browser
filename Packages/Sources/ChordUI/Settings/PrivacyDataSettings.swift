import ChordCore
import ChordStore
import SwiftUI

/// The "Clear browsing data" section of the settings sheet. Website data (cache,
/// cookies, site storage) is cleared across **every Space**; history is cleared
/// from the app's own database. The action is irreversible, so it goes through a
/// confirmation dialog.
struct PrivacyDataSettings: View {
    @Bindable var store: TabStore

    @State private var clearCache = true
    @State private var clearCookies = false
    @State private var clearSiteStorage = false
    @State private var clearHistory = true
    @State private var confirming = false
    @State private var working = false
    @State private var lastCleared: String?

    private var selection: BrowsingDataType {
        var types: BrowsingDataType = []
        if clearCache { types.insert(.cache) }
        if clearCookies { types.insert(.cookies) }
        if clearSiteStorage { types.insert(.siteStorage) }
        if clearHistory { types.insert(.history) }
        return types
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Clear Browsing Data")
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 10) {
                dataToggle($clearCache, "Cached files and images",
                    "Frees disk space. Does not sign you out.")
                dataToggle($clearCookies, "Cookies and other site data",
                    "Signs you out of most websites, in every Space.")
                dataToggle($clearSiteStorage, "Local & session storage",
                    "localStorage, IndexedDB, and service workers.")
                dataToggle($clearHistory, "Browsing history",
                    "The list of pages you have visited.")
            }

            HStack(spacing: 12) {
                Button(role: .destructive) {
                    confirming = true
                } label: {
                    if working {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Clear Data")
                    }
                }
                .disabled(selection.isEmpty || working)

                if let lastCleared {
                    Label(lastCleared, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }

            Text(
                "Website data is cleared for every Space. This cannot be undone."
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            sitePermissionsSection

            Spacer(minLength: 0)
        }
        .task { await store.refreshSitePermissions() }
        .confirmationDialog(
            "Clear the selected browsing data?",
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button("Clear Data", role: .destructive) { performClear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the selected data across every Space.")
        }
    }

    // MARK: - Camera & microphone site permissions

    /// One origin's decision within one Space, collapsed from the per-device
    /// records for display and revocation.
    private struct SiteRow: Identifiable {
        let id: String
        let spaceID: UUID
        let origin: String
        let host: String
        let spaceName: String
        let summary: String
    }

    private var siteRows: [SiteRow] {
        let grouped = Dictionary(grouping: store.sitePermissionRecords) {
            "\($0.spaceID.uuidString)|\($0.origin)"
        }
        return grouped.map { key, records in
            let first = records[0]
            let spaceName = store.spaces.first { $0.id == first.spaceID }?.name ?? "Unknown Space"
            let summary = SitePermissionKind.allCases.compactMap { kind -> String? in
                guard let decision = records.first(where: { $0.kind == kind })?.decision
                else { return nil }
                return "\(kind.label): \(decision == .granted ? "Allowed" : "Blocked")"
            }.joined(separator: " · ")
            return SiteRow(
                id: key,
                spaceID: first.spaceID,
                origin: first.origin,
                host: URL(string: first.origin)?.host ?? first.origin,
                spaceName: spaceName,
                summary: summary
            )
        }
        .sorted { ($0.host, $0.spaceName) < ($1.host, $1.spaceName) }
    }

    @ViewBuilder
    private var sitePermissionsSection: some View {
        Text("Site Permissions")
            .font(.system(size: 13, weight: .semibold))

        if siteRows.isEmpty {
            Text("No sites have been granted or blocked yet.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else {
            Text("Camera, microphone, location, and notification choices you have made, per Space. Removing one asks again next time.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(siteRows) { row in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.host).font(.system(size: 12, weight: .medium))
                            Text("\(row.spaceName) — \(row.summary)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            store.revokeSitePermission(origin: row.origin, spaceID: row.spaceID)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Forget this site’s camera/microphone choice")
                    }
                    .padding(.vertical, 6)
                    if row.id != siteRows.last?.id {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder
    private func dataToggle(
        _ isOn: Binding<Bool>, _ title: String, _ subtitle: String
    ) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12))
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
    }

    private func performClear() {
        let types = selection
        guard !types.isEmpty else { return }
        working = true
        lastCleared = nil
        Task {
            await store.clearBrowsingData(types)
            working = false
            withAnimation { lastCleared = "Cleared" }
        }
    }
}
