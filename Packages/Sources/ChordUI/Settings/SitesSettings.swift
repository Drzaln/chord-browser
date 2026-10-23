import ChordCore
import ChordStore
import SwiftUI

/// Settings → Sites: where a site's links land (ADR 023), and how a site looks
/// (ADR 024).
///
/// Both halves are "small choices about a domain", so they share a pane. Nothing
/// here reloads a page: a routing rule applies to the next arriving link, and an
/// override applies on the next load — the editor says so rather than throwing
/// away what the user is reading.
struct SitesSettings: View {
    @Bindable var store: TabStore

    // Routing rules: the host being typed, and the Space it will point at.
    @State private var newRuleHost = ""
    @State private var newRuleSpaceID: UUID?
    @State private var ruleError = false

    // Site overrides: the host being typed.
    @State private var newOverrideHost = ""
    @State private var overrideError = false
    @State private var expandedPatterns: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            routingSection
            Divider()
            overridesSection
        }
        .onAppear {
            if newRuleSpaceID == nil { newRuleSpaceID = store.visibleSpaces.first?.id }
        }
    }

    // MARK: - Routing rules

    @ViewBuilder
    private var routingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Routing Rules").font(.system(size: 13, weight: .semibold))
            Text(
                "Send a site's links to the Space it belongs in. A rule covers the "
                    + "domain and its subdomains. It is a default: splitting a pane, "
                    + "peeking a link out of a pinned tab, and private windows all win."
            )
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if store.routeRules.isEmpty {
                Text("No rules yet.").font(.system(size: 11)).foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(store.routeRules) { rule in
                        HStack(spacing: 8) {
                            Toggle(
                                "",
                                isOn: Binding(
                                    get: { rule.isEnabled },
                                    set: { enabled in
                                        var updated = rule
                                        updated.isEnabled = enabled
                                        store.setRouteRule(
                                            pattern: updated.pattern,
                                            spaceID: updated.spaceID,
                                            routesNewTabs: updated.routesNewTabs,
                                            isEnabled: enabled
                                        )
                                    }
                                )
                            )
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                            .help("Turn this rule off without deleting it")

                            Text(rule.pattern)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(rule.isEnabled ? .primary : .secondary)

                            Spacer()

                            Picker(
                                "",
                                selection: Binding(
                                    get: { rule.spaceID },
                                    set: { spaceID in
                                        store.setRouteRule(
                                            pattern: rule.pattern,
                                            spaceID: spaceID,
                                            routesNewTabs: rule.routesNewTabs,
                                            isEnabled: rule.isEnabled
                                        )
                                    }
                                )
                            ) {
                                ForEach(store.visibleSpaces) { space in
                                    Text(space.name).tag(space.id)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 130)

                            Toggle(
                                "New tabs",
                                isOn: Binding(
                                    get: { rule.routesNewTabs },
                                    set: { routes in
                                        store.setRouteRule(
                                            pattern: rule.pattern,
                                            spaceID: rule.spaceID,
                                            routesNewTabs: routes,
                                            isEnabled: rule.isEnabled
                                        )
                                    }
                                )
                            )
                            .toggleStyle(.checkbox)
                            .font(.system(size: 11))
                            .help("Also route ⌘-clicked and target=_blank links")

                            Button {
                                store.removeRouteRule(pattern: rule.pattern)
                            } label: {
                                Image(systemName: "trash").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove this rule")
                        }
                        .padding(.vertical, 5)
                        if rule.id != store.routeRules.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }

            HStack(spacing: 8) {
                TextField("example.com", text: $newRuleHost)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .onSubmit(addRule)
                Picker("", selection: $newRuleSpaceID) {
                    ForEach(store.visibleSpaces) { space in
                        Text(space.name).tag(Optional(space.id))
                    }
                }
                .labelsHidden()
                .frame(width: 130)
                Button("Add Rule", action: addRule)
                    .disabled(
                        newRuleHost.trimmingCharacters(in: .whitespaces).isEmpty
                            || newRuleSpaceID == nil
                    )
            }

            if ruleError {
                Text("That does not look like a domain, or reads as a host without a dot.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private func addRule() {
        guard let spaceID = newRuleSpaceID else { return }
        ruleError = !store.setRouteRule(pattern: newRuleHost, spaceID: spaceID)
        if !ruleError { newRuleHost = "" }
    }

    // MARK: - Site overrides

    @ViewBuilder
    private var overridesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Site Overrides").font(.system(size: 13, weight: .semibold))
            Text(
                "Change how a site looks: your own CSS, a script, or elements hidden "
                    + "for good. Covers the domain and its subdomains. Changes apply "
                    + "the next time the page loads — reload the tab to see them."
            )
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if store.siteOverrides.isEmpty {
                Text("No overrides yet.").font(.system(size: 11)).foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(store.siteOverrides) { override in
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { expandedPatterns.contains(override.pattern) },
                                set: { expanded in
                                    if expanded { expandedPatterns.insert(override.pattern) }
                                    else { expandedPatterns.remove(override.pattern) }
                                }
                            )
                        ) {
                            SiteOverrideEditor(store: store, override: override)
                                .padding(.top, 6)
                        } label: {
                            HStack(spacing: 8) {
                                Toggle(
                                    "",
                                    isOn: Binding(
                                        get: { override.isEnabled },
                                        set: { enabled in
                                            var updated = override
                                            updated.isEnabled = enabled
                                            store.setSiteOverride(updated)
                                        }
                                    )
                                )
                                .labelsHidden()
                                .toggleStyle(.checkbox)
                                .help("Turn this override off without deleting it")

                                Text(override.pattern)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(override.isEnabled ? .primary : .secondary)
                                if !override.hiddenSelectors.isEmpty {
                                    Text("\(override.hiddenSelectors.count) hidden")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    store.removeSiteOverride(pattern: override.pattern)
                                } label: {
                                    Image(systemName: "trash").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Remove this override")
                            }
                        }
                        .padding(.vertical, 5)
                        if override.id != store.siteOverrides.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }

            HStack(spacing: 8) {
                TextField("example.com", text: $newOverrideHost)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .onSubmit(addOverride)
                Button("Add Override", action: addOverride)
                    .disabled(newOverrideHost.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if overrideError {
                Text("That does not look like a domain — try example.com.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private func addOverride() {
        guard let normalised = SiteOverrides.normalise(newOverrideHost) else {
            overrideError = true
            return
        }
        overrideError = false
        newOverrideHost = ""
        store.setSiteOverride(SiteOverride(pattern: normalised))
        expandedPatterns.insert(normalised)
    }
}

/// The editor for one site: CSS, JS, and the hidden-element list.
///
/// Writes are explicit — a Save button and dirty state — rather than a live
/// `onChange`. Every save rebuilds the engine's injected script, and a keystroke
/// per save would do that hundreds of times for a paragraph of CSS. It also
/// makes "applies on next load" easy to say honestly: nothing is half-applied
/// while the user is still typing.
private struct SiteOverrideEditor: View {
    @Bindable var store: TabStore
    let override: SiteOverride

    @State private var css = ""
    @State private var js = ""
    @State private var newSelector = ""
    @State private var isDirty = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            labelled("CSS") {
                TextEditor(text: $css)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 80)
                    .padding(4)
                    .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                    .onChange(of: css) { _, _ in isDirty = true }
            }

            labelled("JavaScript") {
                TextEditor(text: $js)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 60)
                    .padding(4)
                    .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                    .onChange(of: js) { _, _ in isDirty = true }
            }

            labelled("Hidden elements") {
                VStack(alignment: .leading, spacing: 6) {
                    if override.hiddenSelectors.isEmpty {
                        Text("None. Add a selector below.")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    } else {
                        ForEach(override.hiddenSelectors, id: \.self) { selector in
                            HStack(spacing: 6) {
                                Text(selector)
                                    .font(.system(size: 11, design: .monospaced))
                                Spacer()
                                Button {
                                    store.removeHiddenSelector(selector, from: override.pattern)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Stop hiding this element")
                            }
                        }
                    }
                    HStack(spacing: 6) {
                        Button("Pick on Page") {
                            store.beginElementPick(forPattern: override.pattern)
                        }
                        .help("Click an element in the page to hide it")
                        Text("or type a selector:")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                        TextField(".sidebar", text: $newSelector)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 200)
                            .onSubmit(addSelector)
                        Button("Hide", action: addSelector)
                            .disabled(newSelector.trimmingCharacters(in: .whitespaces).isEmpty)
                        Text("Use the page's Web Inspector to find a selector.")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
            }

            HStack(spacing: 10) {
                Button("Save") { save() }
                    .disabled(!isDirty)
                if isDirty {
                    Text("Unsaved changes")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    Text("Saved. Reload the page to see it.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        }
        .onAppear {
            css = override.css
            js = override.js
        }
        .onChange(of: override.pattern) { _, _ in
            css = override.css
            js = override.js
            isDirty = false
        }
    }

    @ViewBuilder
    private func labelled<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .medium))
            content()
        }
    }

    private func addSelector() {
        guard store.addHiddenSelector(newSelector, to: override.pattern) else { return }
        newSelector = ""
    }

    private func save() {
        var updated = override
        updated.css = css
        updated.js = js
        store.setSiteOverride(updated)
        isDirty = false
    }
}
