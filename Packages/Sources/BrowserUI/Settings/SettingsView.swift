import BrowserCore
import BrowserExtensions
import BrowserStore
import SwiftUI
import UniformTypeIdentifiers

/// The settings sheet (M8, non-spec: user-requested). Two sections behind a
/// segmented picker: **Privacy & Data** (clear cache / cookies / site storage /
/// history) and **Extensions** (install a `.crx`/`.xpi`, enable or disable it in
/// the active Space, or uninstall it). Presented from `RootView` so it survives
/// the sidebar collapsing beneath it.
public struct SettingsView: View {
    @Bindable var store: TabStore
    let extensions: ExtensionsService?

    private enum Section: String, CaseIterable, Identifiable {
        case general = "General"
        case privacy = "Privacy & Data"
        case extensions = "Extensions"
        var id: String { rawValue }
    }
    @State private var section: Section = .general

    public init(store: TabStore, extensions: ExtensionsService?) {
        self.store = store
        self.extensions = extensions
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Done") { store.isSettingsPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Picker("", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                switch section {
                case .general:
                    GeneralSettings(store: store)
                        .padding(20)
                case .privacy:
                    PrivacyDataSettings(store: store)
                        .padding(20)
                case .extensions:
                    ExtensionsSettings(store: store, extensions: extensions)
                        .padding(20)
                }
            }
        }
        .frame(width: 520, height: 460)
    }
}
