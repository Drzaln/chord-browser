import SwiftUI

/// The Settings search field. `Cmd+F` focuses it (the Find… menu routes the key
/// here while the sheet is up), Escape clears it, and Return opens the first
/// result.
struct SettingsSearchField: View {
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    let onSubmit: () -> Void
    let onEscape: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search settings", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused(focus)
                .onSubmit(onSubmit)
                .onExitCommand(perform: onEscape)
                .accessibilityLabel("Search settings")

            if text.isEmpty {
                Text("⌘F")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            } else {
                Button {
                    text = ""
                    focus.wrappedValue = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .frame(width: 230, height: 26)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(.separator, lineWidth: 1)
        }
    }
}

/// Search results, grouped by nothing and ranked as one list: the catalog has
/// already decided what is most relevant. Each row says which section it is in,
/// why it matched, and — for a find-only note — that it is not a setting.
struct SettingsSearchResults: View {
    let query: String
    let hits: [SettingsSearchHit]
    let onOpen: (SettingsSearchHit) -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if hits.isEmpty {
                empty
            } else {
                Text(
                    hits.count == 1
                        ? "1 result matches “\(query)”"
                        : "\(hits.count) results match “\(query)”"
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

                VStack(spacing: 0) {
                    ForEach(hits) { hit in
                        Button {
                            onOpen(hit)
                        } label: {
                            resultRow(hit)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens \(hit.section.title) at this setting")

                        if hit.id != hits.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 10)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No settings match “\(query)”.", systemImage: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
            Text("Try fewer words, or another name for it — “sleep”, “dark”, “zoom”.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button("Clear Search", action: onClear)
                .controlSize(.small)
                .padding(.top, 2)
        }
        .padding(.top, 24)
    }

    private func resultRow(_ hit: SettingsSearchHit) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: hit.section.systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    SettingsMatchText(text: hit.title, query: query)
                        .font(.system(size: 12, weight: .medium))
                    if hit.isNote {
                        Text("Not a setting")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }

                Text(hit.section.title)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                SettingsMatchText(text: hit.blurb, query: query)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let keyword = hit.matchedKeyword {
                    HStack(spacing: 4) {
                        Text("Matches")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        SettingsMatchText(text: keyword, query: query)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.14), in: Capsule())
                    }
                }
            }

            Spacer(minLength: 8)

            if let shortcut = hit.shortcut {
                Text(shortcut)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
            }

            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

/// Text with the part that matched the query washed in yellow. Uses
/// `AttributedString` so it still wraps as one paragraph in the result row.
struct SettingsMatchText: View {
    let text: String
    let query: String

    var body: some View {
        Text(attributed)
    }

    private var attributed: AttributedString {
        var attributed = AttributedString(text)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return attributed }

        var start = attributed.startIndex
        while start < attributed.endIndex,
              let range = attributed[start...].range(
                  of: needle,
                  options: [.caseInsensitive, .diacriticInsensitive]
              ) {
            attributed[range].backgroundColor = Color.yellow.opacity(0.3)
            attributed[range].foregroundColor = .primary
            start = range.upperBound
        }
        return attributed
    }
}
