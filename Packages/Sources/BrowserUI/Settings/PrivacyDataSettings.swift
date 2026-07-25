import BrowserCore
import BrowserStore
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

            Spacer(minLength: 0)
        }
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
