import BrowserCore
import BrowserStore
import SwiftUI

/// The saved-passwords panel (V6 of the vault).
///
/// Everything the vault holds is visible here, and everything visible here can be
/// deleted. That is not a nicety: a password manager that can accumulate entries
/// the user cannot see or remove is worse than none, which is also why
/// `CredentialVault.reconcile()` exists.
struct PasswordsSettings: View {
    @Bindable var store: TabStore

    @State private var credentials: [Credential] = []
    @State private var neverSaved: [String] = []
    /// Which password is currently revealed, and its text. One at a time: this
    /// is a deliberate look, not a mode to leave switched on.
    @State private var revealed: (id: UUID, secret: String)?
    @State private var authFailed = false
    @State private var pendingDelete: Credential?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            lockSection

            Divider().padding(.vertical, 4)

            Text("Saved Passwords")
                .font(.system(size: 13, weight: .semibold))

            if credentials.isEmpty {
                Text("No passwords saved yet. Chord offers to save one when you sign in.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                credentialList
            }

            if !neverSaved.isEmpty {
                Divider().padding(.vertical, 4)
                neverSavedList
            }

            Spacer(minLength: 0)
        }
        .task {
            store.refreshVaultLock()
            await reload()
        }
        .confirmationDialog(
            "Delete the saved password for \(pendingDelete?.username ?? "")?",
            isPresented: .init(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let credential = pendingDelete else { return }
                pendingDelete = nil
                Task {
                    await store.deleteCredential(credential.id)
                    await reload()
                }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This removes the password from the Keychain. It cannot be undone.")
        }
    }

    /// The lock (V7). Says what the lock does and does not protect, because a
    /// Touch ID prompt implies an OS-enforced guarantee this one does not have:
    /// the items are ordinary Keychain items, readable by anything running as
    /// this user. See `BiometricAuthenticator`.
    private var lockSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: store.isVaultLocked ? "lock.fill" : "lock.open")
                    .foregroundStyle(store.isVaultLocked ? Color.secondary : Color.green)
                Text(store.isVaultLocked ? "Vault locked" : "Vault unlocked")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Lock Now") { store.lockVault() }
                    .font(.system(size: 11))
                    .disabled(store.isVaultLocked)
            }

            Picker("Lock the vault", selection: lockTimeout) {
                ForEach(VaultLockTimeout.presets, id: \.self) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .pickerStyle(.menu)
            .font(.system(size: 12))

            Text(
                "Filling a saved password asks for Touch ID (or your Mac's password) "
                    + "when the vault is locked. It also locks on sleep and screen lock. "
                    + "This keeps someone at your unlocked Mac out of your passwords; "
                    + "it is not encryption."
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var lockTimeout: Binding<VaultLockTimeout> {
        .init(get: { store.vaultLockTimeout }, set: { store.vaultLockTimeout = $0 })
    }

    private var credentialList: some View {
        VStack(spacing: 0) {
            ForEach(credentials) { credential in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(host(of: credential.origin))
                            .font(.system(size: 12, weight: .medium))
                        Text(subtitle(for: credential))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()

                    if revealed?.id == credential.id, let secret = revealed?.secret {
                        Text(secret)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                        Button("Hide") { revealed = nil }
                            .font(.system(size: 11))
                    } else {
                        Button("Reveal") {
                            Task { await reveal(credential) }
                        }
                        .font(.system(size: 11))
                    }

                    Button {
                        pendingDelete = credential
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Delete this saved password")
                }
                .padding(.vertical, 6)

                if credential.id != credentials.last?.id { Divider() }
            }
        }
        .padding(.horizontal, 10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .bottomLeading) {
            if authFailed {
                Text("Authentication was cancelled.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                    .offset(y: 16)
            }
        }
    }

    private var neverSavedList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Never Saved")
                .font(.system(size: 13, weight: .semibold))
            Text("Chord does not offer to save passwords on these sites.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(neverSaved, id: \.self) { origin in
                    HStack {
                        Text(host(of: origin)).font(.system(size: 12))
                        Spacer()
                        Button("Ask Again") {
                            Task {
                                await store.clearNeverSave(origin: origin)
                                await reload()
                            }
                        }
                        .font(.system(size: 11))
                    }
                    .padding(.vertical, 5)
                    if origin != neverSaved.last { Divider() }
                }
            }
            .padding(.horizontal, 10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func reveal(_ credential: Credential) async {
        authFailed = false
        // Touch ID (or the device passcode) stands between a stored password and
        // the screen. A refusal shows nothing and says so plainly.
        guard let secret = await store.revealCredential(credential.id) else {
            authFailed = true
            return
        }
        revealed = (credential.id, secret)
    }

    private func reload() async {
        credentials = await store.allCredentials()
        neverSaved = await store.neverSaveOrigins()
        revealed = nil
    }

    private func host(of origin: String) -> String {
        URL(string: origin)?.host ?? origin
    }

    private func subtitle(for credential: Credential) -> String {
        let name = credential.username.isEmpty ? "(no username)" : credential.username
        guard let lastUsed = credential.lastUsedAt else { return name }
        return "\(name) — last used \(lastUsed.formatted(date: .abbreviated, time: .omitted))"
    }
}
