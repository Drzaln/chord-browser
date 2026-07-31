import BrowserStore
import SwiftUI

/// "Save this password?" — shown after a login is submitted (V5 of the vault).
///
/// A bar rather than a sheet, deliberately: this appears at the moment a sign-in
/// completes, usually while the page is still navigating, and a modal would
/// interrupt something the user is in the middle of. Declining is one click and
/// the page keeps working either way.
struct CredentialSaveBar: View {
    let prompt: CredentialSavePrompt
    let onDecision: (CredentialSaveDecision) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                // "Update" when a password is already saved for this login:
                // overwriting a working password by accident is worse than
                // declining to save a new one, so the two must not read alike.
                Text(prompt.isUpdate ? "Update saved password?" : "Save password?")
                    .font(.system(size: 12, weight: .semibold))
                Text(
                    prompt.username.isEmpty
                        ? prompt.host
                        : "\(prompt.username) — \(prompt.host)"
                )
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Button(prompt.isUpdate ? "Update" : "Save") { onDecision(.save) }
                .keyboardShortcut(.defaultAction)

            Button("Not Now") { onDecision(.dismiss) }

            // Deliberately last and least prominent: it is the only choice here
            // that is remembered, and it silences the site permanently.
            Button("Never") { onDecision(.never) }
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            prompt.isUpdate
                ? "Update the saved password for \(prompt.host)?"
                : "Save the password for \(prompt.host)?"
        )
    }
}
