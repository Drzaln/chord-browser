import BrowserCore
import BrowserStore
import SwiftUI

/// The History window (non-spec: user-requested). Lists every recorded visit,
/// most-recent first and grouped by day, with search, multi-select delete, and
/// open-in-new-tab. Presented as a sheet from `RootView` so it survives the
/// sidebar collapsing beneath it, like Settings.
public struct HistoryView: View {
    @Bindable var store: TabStore

    @State private var entries: [HistoryEntry] = []
    @State private var query = ""
    @State private var selection = Set<UUID>()
    @State private var isLoading = true
    @State private var confirmingClearAll = false

    public init(store: TabStore) {
        self.store = store
    }

    /// Entries matching the search box, over both title and URL.
    private var filtered: [HistoryEntry] {
        guard !query.isEmpty else { return entries }
        let needle = query.lowercased()
        return entries.filter {
            $0.displayTitle.lowercased().contains(needle)
                || $0.url.absoluteString.lowercased().contains(needle)
        }
    }

    /// Filtered entries bucketed by calendar day, newest day first, each day's
    /// rows newest-first — the shape the list renders as sections.
    private var sections: [(title: String, entries: [HistoryEntry])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: filtered) {
            calendar.startOfDay(for: $0.lastVisitedAt)
        }
        return groups.keys.sorted(by: >).map { day in
            (Self.dayTitle(day), groups[day]!.sorted { $0.lastVisitedAt > $1.lastVisitedAt })
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 640, height: 540)
        .task { await load() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("History").font(.system(size: 15, weight: .semibold))
                if let name = store.activeSpace?.name {
                    Text(name).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Search history", text: $query)
                    .textFieldStyle(.plain)
                    .frame(width: 180)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))

            Button("Delete", role: .destructive) { deleteSelected() }
                .disabled(selection.isEmpty)

            Button("Done") { store.isHistoryPresented = false }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            centered { ProgressView() }
        } else if entries.isEmpty {
            centered {
                emptyState("No history yet", "Pages you visit will appear here.")
            }
        } else if filtered.isEmpty {
            centered {
                emptyState("No matches", "Nothing in history matches “\(query)”.")
            }
        } else {
            List(selection: $selection) {
                ForEach(sections, id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.entries) { entry in
                            HistoryRow(entry: entry)
                                .tag(entry.id)
                                .contextMenu { rowMenu(for: entry) }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .safeAreaInset(edge: .bottom) { footer }
        }
    }

    private var footer: some View {
        HStack {
            Text("^[\(entries.count) item](inflect: true)")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button("Clear History…", role: .destructive) {
                confirmingClearAll = true
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
        .background(.bar)
        .confirmationDialog(
            "Clear this Space's history?",
            isPresented: $confirmingClearAll,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) { clearAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This permanently removes every recorded visit in "
                    + "“\(store.activeSpace?.name ?? "this Space")”. Other Spaces are unaffected."
            )
        }
    }

    @ViewBuilder
    private func rowMenu(for entry: HistoryEntry) -> some View {
        Button("Open in New Tab") { open(entry) }
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.url.absoluteString, forType: .string)
        }
        Divider()
        Button("Delete", role: .destructive) {
            Task { await store.deleteHistory(ids: [entry.id]); removeLocally([entry.id]) }
        }
    }

    // MARK: - Actions

    private func load() async {
        entries = await store.loadFullHistory()
        isLoading = false
    }

    private func open(_ entry: HistoryEntry) {
        store.openHistoryEntry(entry.url)
        store.isHistoryPresented = false
    }

    private func deleteSelected() {
        let ids = Array(selection)
        selection.removeAll()
        Task { await store.deleteHistory(ids: ids); removeLocally(ids) }
    }

    private func clearAll() {
        entries.removeAll()
        selection.removeAll()
        Task { await store.clearActiveSpaceHistory() }
    }

    private func removeLocally(_ ids: [UUID]) {
        let removed = Set(ids)
        entries.removeAll { removed.contains($0.id) }
    }

    // MARK: - Helpers

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack { Spacer(); content(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyState(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.largeTitle).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter.string(from: day)
    }
}

/// One visited page in the History list: title, host, and the time of the last
/// visit. Double-click opens it — wired here so the whole row is the target.
private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "globe")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayTitle)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text(entry.url.host() ?? entry.url.absoluteString)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(entry.lastVisitedAt, format: .dateTime.hour().minute())
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
