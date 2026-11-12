import AppKit
import ChordCore
import ChordExtensions
import ChordStore
import SwiftUI

/// The settings sheet (M8, non-spec: user-requested): a section picker over the
/// panes, and a search field that finds any row by name or synonym.
///
/// The panes are drawn from `SettingsCatalog`'s row enums (see `SettingsRows`),
/// so the thing search reads and the thing the sheet shows are the same list.
/// `Cmd+F` focuses the field: the Find… menu and a local key monitor both route
/// it here while the sheet is up, instead of to find-in-page behind it.
public struct SettingsView: View {
    @Bindable var store: TabStore
    /// The presenting window's state — this sheet's Done button closes it.
    @Bindable var windowState: WindowState
    let extensions: ExtensionsService?
    let bookmarks: BookmarksStore?

    /// The tab row's own width, measured, so the sheet fits it.
    @State private var pickerWidth: CGFloat = 0

    /// The open section lives on the window (other sheets deep-link to it by
    /// title), so the picker binds through it.
    private var section: SettingsSection {
        SettingsSection.allCases.first { $0.title == windowState.settingsSection } ?? .general
    }

    private var sectionBinding: Binding<SettingsSection> {
        Binding(
            get: { section },
            set: { windowState.settingsSection = $0.title }
        )
    }

    @State private var query = ""
    /// Set after opening a result; cleared a few seconds later.
    @State private var highlightedRowID: String?
    /// Bumped per jump so the scroll happens after the new pane is laid out.
    @State private var scrollRequest = 0
    @State private var scrollTarget: String?
    @State private var highlightClearTask: Task<Void, Never>?
    /// Catches `Cmd+F` while the sheet is key, so the menu's Find… item cannot
    /// open find-in-page behind it. Removed on disappear.
    @State private var searchKeyMonitor: Any?
    @FocusState private var searchFocused: Bool

    public init(
        store: TabStore, windowState: WindowState,
        extensions: ExtensionsService?, bookmarks: BookmarksStore?
    ) {
        self.store = store
        self.windowState = windowState
        self.extensions = extensions
        self.bookmarks = bookmarks
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool { !trimmedQuery.isEmpty }

    private var hits: [SettingsSearchHit] {
        SettingsCatalog.search(trimmedQuery)
    }

    public var body: some View {
        VStack(spacing: 0) {
            header

            if isSearching {
                Divider()
                ScrollView {
                    SettingsSearchResults(
                        query: trimmedQuery,
                        hits: hits,
                        onOpen: open,
                        onClear: clearSearch
                    )
                    .padding(20)
                }
            } else {
                Picker("", selection: sectionBinding) {
                    ForEach(SettingsSection.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // Its natural width, not the sheet's: measured below so the
                // sheet grows with the labels instead of clipping them.
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                    pickerWidth = $0
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        pane
                            .padding(20)
                    }
                    // A section always opens at its top, and a jump can ask for
                    // a row immediately after the pane changes.
                    .id(section)
                    .environment(\.settingsHighlightedRow, highlightedRowID)
                    .task(id: scrollRequest) {
                        await scrollToTarget(using: proxy)
                    }
                }
            }
        }
        // As wide as the tab row needs, never narrower than the sections were
        // laid out for. Sized from the row alone: the sections' text would
        // ask for one long line each.
        .frame(width: max(720, pickerWidth + 40), height: 480)
        .onChange(of: windowState.settingsSearchFocusCount) { _, _ in
            searchFocused = true
        }
        .onAppear(perform: installSearchKeyMonitor)
        .onDisappear {
            highlightClearTask?.cancel()
            if let searchKeyMonitor {
                NSEvent.removeMonitor(searchKeyMonitor)
            }
            searchKeyMonitor = nil
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Settings").font(.system(size: 15, weight: .semibold))

            Spacer()

            SettingsSearchField(
                text: $query,
                focus: $searchFocused,
                onSubmit: openFirstHit,
                onEscape: escapeSearch
            )

            Button("Done") { windowState.isSettingsPresented = false }
                // While searching, Return belongs to the search field. The
                // default-action button would otherwise close the sheet first.
                .keyboardShortcut(isSearching ? nil : KeyboardShortcut.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var pane: some View {
        switch section {
        case .general:
            GeneralSettings(store: store, windowState: windowState)
        case .sites:
            SitesSettings(store: store)
        case .passwords:
            PasswordsSettings(store: store)
        case .privacy:
            PrivacyDataSettings(store: store)
        case .extensions:
            ExtensionsSettings(store: store, windowState: windowState, extensions: extensions)
        case .bookmarks:
            BookmarksSettings(store: store, windowState: windowState, bookmarks: bookmarks)
        case .agents:
            AgentsSettings(store: store)
        case .updates:
            UpdateSettings()
        }
    }

    // MARK: - Search

    private func openFirstHit() {
        guard let first = hits.first else { return }
        open(first)
    }

    /// Return or a click: close the results, show the section, and mark the row
    /// so the eye lands on the right control. Notes have no row to mark; they
    /// have already said where the control really lives.
    private func open(_ hit: SettingsSearchHit) {
        query = ""
        windowState.settingsSection = hit.section.title
        highlightedRowID = hit.isNote ? nil : hit.id
        scrollTarget = hit.isNote ? nil : hit.id
        scrollRequest += 1
        scheduleHighlightClear()
    }

    private func clearSearch() {
        query = ""
        highlightedRowID = nil
        searchFocused = true
    }

    private func escapeSearch() {
        if query.isEmpty {
            windowState.isSettingsPresented = false
        } else {
            clearSearch()
        }
    }

    private func scrollToTarget(using proxy: ScrollViewProxy) async {
        guard let target = scrollTarget else { return }
        // The pane swap and its layout happen on the next run-loop turn; the
        // short sleep is enough for the new ScrollView to know where the row is.
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(60))
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(target, anchor: .center)
        }
        scrollTarget = nil
    }

    private func scheduleHighlightClear() {
        highlightClearTask?.cancel()
        guard highlightedRowID != nil else { return }
        highlightClearTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                highlightedRowID = nil
            }
        }
    }

    /// `Cmd+F` belongs to the sheet while it is up. The menu route through
    /// `WindowState.focusSettingsSearch()` covers the case where the menu's
    /// focused value reaches the sheet; this monitor covers the other case, and
    /// consumes the event so Find… cannot also open behind the sheet.
    private func installSearchKeyMonitor() {
        guard searchKeyMonitor == nil else { return }
        let focus = $searchFocused
        searchKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "f",
                  NSApp.keyWindow?.isSheet == true
            else { return event }
            focus.wrappedValue = true
            return nil
        }
    }
}
