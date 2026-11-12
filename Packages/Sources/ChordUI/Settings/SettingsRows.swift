import SwiftUI

/// Lays out one settings pane from its row enum.
///
/// Every pane's `body` is this view plus an exhaustive `switch` over its row
/// enum. That is the structural half of "every visible row has a catalog
/// entry": there is no other way for a pane to draw a row, and the enum is the
/// catalog's key. Adding a case is a compile error until the pane draws it and
/// a test failure until `SettingsCatalog` describes it.
struct SettingsRows<Row: SettingsRowType, Content: View>: View {
    let section: SettingsSection
    var spacing: CGFloat = 22
    /// The panes that used `Divider().padding(.vertical, 4)` keep that spacing.
    var dividerPadding: CGFloat = 0
    /// Rows that exist but are not drawn in the current state (Never Saved,
    /// while the list is empty).
    var hiding: Set<Row> = []
    private let content: (Row) -> Content

    init(
        section: SettingsSection,
        spacing: CGFloat = 22,
        dividerPadding: CGFloat = 0,
        hiding: Set<Row> = [],
        @ViewBuilder content: @escaping (Row) -> Content
    ) {
        assert(
            Row.section == section,
            "SettingsRows<\(Row.self)> belongs to \(Row.section), not \(section)"
        )
        self.section = section
        self.spacing = spacing
        self.dividerPadding = dividerPadding
        self.hiding = hiding
        self.content = content
    }

    private var visibleRows: [Row] {
        Row.allCases.filter { !hiding.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(visibleRows.enumerated()), id: \.element) { index, row in
                if index > 0 {
                    Divider().padding(.vertical, dividerPadding)
                }
                SettingsRowAnchor(id: row.rawValue) {
                    content(row)
                }
            }
        }
    }
}

/// Gives a row its scroll identity and the brief wash shown after a search
/// result sends you to it.
struct SettingsRowAnchor<Content: View>: View {
    let id: String
    @Environment(\.settingsHighlightedRow) private var highlightedRow
    private let content: Content

    init(id: String, @ViewBuilder content: () -> Content) {
        self.id = id
        self.content = content()
    }

    var body: some View {
        content
            .background {
                if highlightedRow == id {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1)
                        }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: highlightedRow)
            .id(id)
    }
}

private struct SettingsHighlightedRowKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The row a search result just opened, highlighted until it is cleared.
    var settingsHighlightedRow: String? {
        get { self[SettingsHighlightedRowKey.self] }
        set { self[SettingsHighlightedRowKey.self] = newValue }
    }
}
