import ChordCore
import ChordStore
import SwiftUI

/// The "General" section of the settings sheet (non-spec: user-requested): the
/// default search engine and what a new tab opens to. Both write straight
/// through to the store, which persists them to `UserDefaults`.
struct GeneralSettings: View {
    @Bindable var store: TabStore
    /// The window this view belongs to — its selection, its Space.
    @Bindable var windowState: WindowState

    // Search engine. `customName`/`customTemplate` hold the editable fields while
    // "Custom" is selected; they are folded back into a `.custom` engine on edit.
    @State private var isCustomEngine = false
    @State private var customName = ""
    @State private var customTemplate = ""

    // New-tab behaviour.
    @State private var newTabKind: NewTabKind = .searchEngine
    @State private var customURL = ""

    // User agent. `customUA` holds the editable field while "Custom" is selected.
    @State private var isCustomUA = false
    @State private var customUA = ""

    // Per-domain rules (§9.6): the domain being typed into the add field, and
    // the preset chosen beside it.
    @State private var newOverrideDomain = ""
    @State private var newOverridePreset: UserAgentPreference = .chrome
    @State private var overrideError = false

    private enum NewTabKind: String, CaseIterable, Identifiable {
        case blank, searchEngine, custom
        var id: String { rawValue }
        var label: String {
            switch self {
            case .blank: "Blank page"
            case .searchEngine: "Search engine home"
            case .custom: "Specific page"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            searchEngineSection
            Divider()
            newTabSection
            Divider()
            userAgentSection
            Divider()
            hibernationSection
            Divider()
            gestureSection
            Divider()
            developerSection
            // No trailing `Spacer` here. Inside the sheet's `ScrollView` a
            // greedy spacer absorbs the overflow instead of letting it scroll,
            // so the section below the fold — the per-site UA rules — was
            // rendered and simply unreachable.
        }
        .onAppear(perform: syncFromStore)
    }

    // MARK: - Search engine

    @ViewBuilder
    private var searchEngineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Search Engine").font(.system(size: 13, weight: .semibold))
            Text("Where the address bar and command bar send what you type.")
                .font(.system(size: 11)).foregroundStyle(.secondary)

            Picker("", selection: engineSelection) {
                ForEach(SearchEngine.builtIns, id: \.self) { engine in
                    Text(engine.displayName).tag(engine.displayName)
                }
                Text("Custom…").tag("__custom__")
            }
            .labelsHidden()
            .frame(maxWidth: 260)

            if isCustomEngine {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Name", text: $customName)
                        .onChange(of: customName) { _, _ in commitCustomEngine() }
                    TextField("Query URL (use %s for the query)", text: $customTemplate)
                        .onChange(of: customTemplate) { _, _ in commitCustomEngine() }
                    Text("Example: https://example.com/search?q=%s")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 360)
            }
        }
    }

    /// The picker binds to a string tag so the built-ins and the "Custom" option
    /// coexist; selecting a built-in writes it straight to the store.
    private var engineSelection: Binding<String> {
        Binding(
            get: { isCustomEngine ? "__custom__" : store.searchEngine.displayName },
            set: { tag in
                if tag == "__custom__" {
                    isCustomEngine = true
                    commitCustomEngine()
                } else if let engine = SearchEngine.builtIns.first(where: { $0.displayName == tag }) {
                    isCustomEngine = false
                    store.searchEngine = engine
                }
            }
        )
    }

    private func commitCustomEngine() {
        store.searchEngine = .custom(name: customName, template: customTemplate)
    }

    // MARK: - New tab

    @ViewBuilder
    private var newTabSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Tab Opens").font(.system(size: 13, weight: .semibold))

            Picker("", selection: newTabBinding) {
                ForEach(NewTabKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if newTabKind == .custom {
                TextField("https://example.com", text: $customURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                    .onChange(of: customURL) { _, _ in commitCustomURL() }
            }
        }
    }

    private var newTabBinding: Binding<NewTabKind> {
        Binding(
            get: { newTabKind },
            set: { kind in
                newTabKind = kind
                switch kind {
                case .blank: store.newTabBehavior = .blank
                case .searchEngine: store.newTabBehavior = .searchEngine
                case .custom: commitCustomURL()
                }
            }
        )
    }

    // MARK: - User agent

    @ViewBuilder
    private var userAgentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("User Agent").font(.system(size: 13, weight: .semibold))
            Text(
                "How the browser identifies itself to sites. Change it for the "
                    + "occasional site that blocks non-Chrome browsers or serves a "
                    + "better mobile layout. Takes effect on the next page load."
            )
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Picker("", selection: userAgentSelection) {
                ForEach(UserAgentPreference.presets, id: \.self) { preset in
                    Text(preset.displayName).tag(preset.displayName)
                }
                Text("Custom…").tag("__custom__")
            }
            .labelsHidden()
            .frame(maxWidth: 260)

            if isCustomUA {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Paste a full User-Agent string", text: $customUA, axis: .vertical)
                        .lineLimit(1...3)
                        .onChange(of: customUA) { _, _ in commitCustomUA() }
                    Text("Leave empty to use the browser's own User-Agent.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 360)
            }

            perDomainRules
        }
    }

    /// The per-domain map §9.6 asked for. It beats the global setting above,
    /// including a per-domain "Default", which is how you carve out the one site
    /// a global spoof breaks — Google Meet under the Firefox UA being the
    /// standing example.
    @ViewBuilder
    private var perDomainRules: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Per-Site Rules")
                .font(.system(size: 12, weight: .semibold))
                .padding(.top, 6)
            Text(
                "A rule covers the domain and its subdomains, and beats the setting "
                    + "above. Set a site to “Default” to keep your own User-Agent there "
                    + "while everywhere else is overridden."
            )
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if !store.userAgentOverrides.isEmpty {
                VStack(spacing: 0) {
                    ForEach(store.userAgentOverrides) { override in
                        HStack(spacing: 8) {
                            Text(override.domain)
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            Picker("", selection: presetBinding(for: override)) {
                                ForEach(UserAgentPreference.presets, id: \.self) { preset in
                                    Text(preset.displayName).tag(preset.displayName)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 190)

                            Button {
                                store.removeUserAgentOverride(domain: override.domain)
                            } label: {
                                Image(systemName: "trash").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove this rule")
                        }
                        .padding(.vertical, 5)
                        if override.id != store.userAgentOverrides.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: 460)
            }

            HStack(spacing: 8) {
                TextField("example.com", text: $newOverrideDomain)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .onSubmit(addOverride)
                Picker("", selection: $newOverridePreset) {
                    ForEach(UserAgentPreference.presets, id: \.self) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
                Button("Add", action: addOverride)
                    .disabled(newOverrideDomain.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if overrideError {
                Text("That does not look like a domain — try example.com.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private func presetBinding(for override: UserAgentOverride) -> Binding<String> {
        Binding(
            get: { override.preference.displayName },
            set: { name in
                guard let preset = UserAgentPreference.presets.first(where: {
                    $0.displayName == name
                }) else { return }
                store.setUserAgentOverride(domain: override.domain, preference: preset)
            }
        )
    }

    private func addOverride() {
        overrideError = !store.setUserAgentOverride(
            domain: newOverrideDomain, preference: newOverridePreset
        )
        if !overrideError { newOverrideDomain = "" }
    }

    /// Binds the picker to a string tag so the presets and "Custom" coexist,
    /// mirroring the search-engine picker.
    private var userAgentSelection: Binding<String> {
        Binding(
            get: { isCustomUA ? "__custom__" : store.userAgent.displayName },
            set: { tag in
                if tag == "__custom__" {
                    // Seed the manual field from the UA currently in effect, so
                    // editing starts from a real string to tweak rather than a
                    // blank box. `resolvedUserAgent` is nil only for Default, in
                    // which case the browser's own completed UA is the template.
                    if customUA.isEmpty {
                        customUA = store.userAgent.editableTemplate
                    }
                    isCustomUA = true
                    commitCustomUA()
                } else if let preset = UserAgentPreference.presets.first(
                    where: { $0.displayName == tag }
                ) {
                    isCustomUA = false
                    store.userAgent = preset
                }
            }
        )
    }

    private func commitCustomUA() {
        store.userAgent = .custom(customUA)
    }

    // MARK: - Hibernation / auto-archive

    @ViewBuilder
    private var hibernationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Archive Inactive Tabs").font(.system(size: 13, weight: .semibold))
            Text(
                "Unpinned tabs you haven't touched for this long are moved to the "
                    + "archive, reachable from the command bar. Pinned tabs and tabs "
                    + "playing audio are never archived."
            )
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Picker("", selection: idleWindowBinding) {
                ForEach(IdleWindow.presets, id: \.self) { window in
                    Text(window.displayName).tag(window)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 200)
        }
    }

    private var idleWindowBinding: Binding<IdleWindow> {
        Binding(
            get: {
                // Snap an off-preset stored value (older builds) to the closest tag.
                IdleWindow.presets.contains(store.idleWindow) ? store.idleWindow : .default
            },
            set: { store.idleWindow = $0 }
        )
    }

    // MARK: - Gestures

    @ViewBuilder
    private var gestureSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Gestures").font(.system(size: 13, weight: .semibold))
            Text(
                "Swipe right on a page that has nothing to undo — it closes the "
                    + "tab (or the Little Chord panel). Turn this off to restore "
                    + "WebKit's default, where the swipe just does nothing."
            )
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Toggle(
                "Swipe right closes a tab with no back history",
                isOn: Binding(
                    get: { store.swipeToCloseEnabled },
                    set: { store.swipeToCloseEnabled = $0 }
                )
            )
            .toggleStyle(.checkbox)
        }
    }

    private func commitCustomURL() {
        // Fall back to https:// so a bare host still resolves to a real page.
        let trimmed = customURL.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        if let url = URL(string: candidate) {
            store.newTabBehavior = .custom(url)
        }
    }

    // MARK: - Developer mode

    @ViewBuilder
    private var developerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Developer").font(.system(size: 13, weight: .semibold))
            Text(
                "Enables the Web Inspector (right-click “Inspect Element” and the "
                    + "detached inspector window) and the DRM Diagnostics panel in "
                    + "the Develop menu. Uses a private WebKit flag; off by default, "
                    + "including in release builds."
            )
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Toggle(
                "Developer Mode",
                isOn: Binding(
                    get: { store.developerMode },
                    set: { store.developerMode = $0 }
                )
            )
            .toggleStyle(.checkbox)
        }
    }

    // MARK: - Load current values

    private func syncFromStore() {
        switch store.searchEngine {
        case .custom(let name, let template):
            isCustomEngine = true
            customName = name
            customTemplate = template
        default:
            isCustomEngine = false
        }

        switch store.newTabBehavior {
        case .blank: newTabKind = .blank
        case .searchEngine: newTabKind = .searchEngine
        case .custom(let url):
            newTabKind = .custom
            customURL = url.absoluteString
        }

        switch store.userAgent {
        case .custom(let value):
            isCustomUA = true
            customUA = value
        default:
            isCustomUA = false
        }
    }
}
