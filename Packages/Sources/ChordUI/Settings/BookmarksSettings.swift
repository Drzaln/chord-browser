import ChordCore
import ChordStore
import SwiftUI

/// Settings › Bookmarks: the store behind `chrome.bookmarks`, made visible.
struct BookmarksSettings: View {
    @Bindable var store: TabStore
    @Bindable var windowState: WindowState
    let bookmarks: BookmarksStore?

    @State private var title = ""
    @State private var address = ""
    @State private var error: String?

    private var items: [Bookmark] {
        (bookmarks?.items ?? [])
            .filter { $0.url != nil }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Bookmarks").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(items.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                TextField("Title", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(width: 160)
                TextField("https://…", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { add() }
                Button("Add") { add() }
                    .disabled(validURL == nil)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            if items.isEmpty {
                Text("No bookmarks. Add one above; extension `chrome.bookmarks` writes show up here.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(items) { item in
                            row(item)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .task { bookmarks?.load() }
    }

    private func row(_ item: Bookmark) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "bookmark.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title.isEmpty ? (item.url?.host() ?? "Bookmark") : item.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(item.url?.absoluteString ?? "")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Open") {
                guard let url = item.url else { return }
                windowState.isSettingsPresented = false
                store.newTab(url: url, in: store.focusedWindow)
            }
            .buttonStyle(.borderless)
            Button(role: .destructive) {
                bookmarks?.remove(item.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }

    private var validURL: URL? {
        let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host() != nil
        else { return nil }
        return url
    }

    private func add() {
        guard let url = validURL else {
            error = "Enter an http or https address."
            return
        }
        error = nil
        bookmarks?.insert(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            url: url, parentID: BookmarksStore.barID
        )
        title = ""
        address = ""
    }
}
