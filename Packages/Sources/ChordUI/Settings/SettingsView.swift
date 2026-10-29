import ChordCore
import ChordExtensions
import ChordStore
import SwiftUI
import UniformTypeIdentifiers

/// The settings sheet (M8, non-spec: user-requested). Two sections behind a
/// segmented picker: **Privacy & Data** (clear cache / cookies / site storage /
/// history) and **Extensions** (install a `.crx`/`.xpi`, enable or disable it in
/// the active Space, or uninstall it). Presented from `RootView` so it survives
/// the sidebar collapsing beneath it.
public struct SettingsView: View {
    @Bindable var store: TabStore
    /// The presenting window's state — this sheet's Done button closes it.
    @Bindable var windowState: WindowState
    let extensions: ExtensionsService?
    let bookmarks: BookmarksStore?

    private enum Section: String, CaseIterable, Identifiable {
        case general = "General"
        case sites = "Sites"
        case passwords = "Passwords"
        case privacy = "Privacy & Data"
        case extensions = "Extensions"
        case bookmarks = "Bookmarks"
        case updates = "Updates"
        var id: String { rawValue }
    }
    /// The tab row's own width, measured, so the sheet fits it.
    @State private var pickerWidth: CGFloat = 0

    private var section: Binding<Section> {
        Binding(
            get: { Section(rawValue: windowState.settingsSection) ?? .general },
            set: { windowState.settingsSection = $0.rawValue }
        )
    }

    public init(
        store: TabStore, windowState: WindowState,
        extensions: ExtensionsService?, bookmarks: BookmarksStore?
    ) {
        self.store = store
        self.windowState = windowState
        self.extensions = extensions
        self.bookmarks = bookmarks
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Done") { windowState.isSettingsPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Picker("", selection: section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // Its natural width, not the sheet's: measured below so the sheet
            // grows with the labels instead of clipping them at both edges.
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                pickerWidth = $0
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                switch section.wrappedValue {
                case .general:
                    GeneralSettings(store: store, windowState: windowState)
                        .padding(20)
                case .sites:
                    SitesSettings(store: store)
                        .padding(20)
                case .passwords:
                    PasswordsSettings(store: store)
                        .padding(20)
                case .privacy:
                    PrivacyDataSettings(store: store)
                        .padding(20)
                case .extensions:
                    ExtensionsSettings(store: store, windowState: windowState, extensions: extensions)
                        .padding(20)
                case .bookmarks:
                    BookmarksSettings(
                        store: store, windowState: windowState, bookmarks: bookmarks
                    )
                    .padding(20)
                case .updates:
                    UpdateSettings()
                        .padding(20)
                }
            }
        }
        // As wide as the tab row needs, never narrower than the sections were
        // laid out for. Sized from the row alone: the sections' text would
        // ask for one long line each. A fixed 720 clipped General and Updates
        // once a seventh tab, Bookmarks, was added.
        .frame(width: max(720, pickerWidth + 40), height: 480)
    }
}
