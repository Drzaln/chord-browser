import AppKit
import ChordCore
import ChordStore
import SwiftUI

/// Edits a Space's name, icon, and colour (the custom-emoji/colour feature).
///
/// Icon and gradient are already free-form persisted columns, so this needs no
/// schema change — it just gives the two fields a UI. The colour is picked as a
/// single accent and expanded into the two-stop gradient the sidebar theming
/// expects, so the Space still reads as a gradient rather than a flat fill.
struct SpaceEditor: View {
    @Bindable var store: TabStore
    let space: Space

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var icon: String
    @State private var color: Color
    @FocusState private var iconFocused: Bool

    init(store: TabStore, space: Space) {
        self.store = store
        self.space = space
        _name = State(initialValue: space.name)
        _icon = State(initialValue: space.iconSymbol)
        _color = State(initialValue: Self.color(from: space.gradient.first))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Space")
                .font(.headline)

            HStack(spacing: 12) {
                preview
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Name", text: $name)
                        .textFieldStyle(.roundedBorder)
                    HStack(spacing: 8) {
                        TextField("Icon", text: $icon)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .focused($iconFocused)
                            // The macOS emoji picker appends into the focused
                            // field; keep a single glyph so an icon is one emoji.
                            // Only fires for a custom glyph — an ASCII SF Symbol
                            // name is left alone.
                            .onChange(of: icon) { _, new in
                                if isEmoji(new), new.count > 1 {
                                    icon = String(new.suffix(1))
                                }
                            }
                        Button {
                            // Focus the field, then open the system Character
                            // Viewer — its selection inserts into the first
                            // responder, which is now the icon field.
                            iconFocused = true
                            DispatchQueue.main.async {
                                NSApp.orderFrontCharacterPalette(nil)
                            }
                        } label: {
                            Image(systemName: "face.smiling")
                        }
                        .help("Choose Emoji…")
                        ColorPicker("Colour", selection: $color, supportsOpacity: false)
                            .labelsHidden()
                        Text("Emoji or SF Symbol name")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    /// Shows the icon on the chosen colour, so the choice is visible before it
    /// is committed.
    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(gradient)
            Group {
                if isEmoji(icon) {
                    Text(icon).font(.system(size: 22))
                } else {
                    Image(systemName: icon.isEmpty ? "circle" : icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: 48, height: 48)
    }

    private var gradient: LinearGradient {
        SpaceTheme.gradient(stops: stops())
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { store.renameSpace(space.id, to: trimmed) }
        store.setSpaceAppearance(space.id, icon: icon, gradient: stops())
        dismiss()
    }

    /// The picked accent plus a darker sibling, so the sidebar keeps a gradient
    /// rather than a flat wash.
    private func stops() -> [ColorHex] {
        let base = Self.hex(from: color)
        return [base, base.darkened(by: 0.28)]
    }

    private func isEmoji(_ string: String) -> Bool {
        string.unicodeScalars.contains { $0.value > 0x7F }
    }

    // MARK: - Colour conversion (AppKit-side, kept out of Core)

    private static func color(from hex: ColorHex?) -> Color {
        guard let c = hex?.components else { return .accentColor }
        return Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: 1)
    }

    private static func hex(from color: Color) -> ColorHex {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .gray
        return ColorHex(String(
            format: "#%02X%02X%02X",
            Int((ns.redComponent * 255).rounded()),
            Int((ns.greenComponent * 255).rounded()),
            Int((ns.blueComponent * 255).rounded())
        ))
    }
}

private extension ColorHex {
    /// A darker variant, for deriving a gradient's second stop from one colour.
    func darkened(by amount: Double) -> ColorHex {
        guard let c = components else { return self }
        let f = max(0, 1 - amount)
        return ColorHex(String(
            format: "#%02X%02X%02X",
            Int((c.red * f * 255).rounded()),
            Int((c.green * f * 255).rounded()),
            Int((c.blue * f * 255).rounded())
        ))
    }
}
