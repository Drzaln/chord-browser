import BrowserCore
import BrowserStore
import SwiftUI

/// The key that fills a saved password (V6 of the vault).
///
/// It appears only when the page is showing a login **and** there is something
/// saved for that exact origin — an affordance that is always present would be
/// noise on every page, and one that appears with nothing behind it is worse.
///
/// **Clicking it is the user gesture** threat-model rule 4 requires. There is
/// deliberately no automatic path to `fillCredential` anywhere in the app: no
/// fill on load, no fill on focus. With one saved account the click fills; with
/// several it offers a menu first, because picking the wrong account is a real
/// mistake on the sites where Spaces exist in the first place.
struct CredentialFillButton: View {
    @Bindable var store: TabStore
    @Bindable var windowState: WindowState

    @State private var status: Status?

    private enum Status: Equatable {
        case filled
        case failed(String)
    }

    private var paneID: UUID? { store.selectedTab(in: windowState)?.focusedPaneID }

    private var isLogin: Bool {
        guard let paneID else { return false }
        return store.runtime(for: paneID).loginForm?.kind == .login
    }

    /// Published by the store when the page reports — see
    /// `TabStore.refreshFillableCredentials`.
    private var matches: [Credential] {
        guard let paneID else { return [] }
        return store.runtime(for: paneID).fillableCredentials
    }

    var body: some View {
        Group {
            if isLogin && !matches.isEmpty {
                content
            }
        }
        // Nothing polls the idle clock (§6.4), so the lock is re-evaluated when
        // the button is about to be looked at.
        .onAppear { store.refreshVaultLock() }
    }

    @ViewBuilder private var content: some View {
        if matches.count == 1, let only = matches.first {
            button(help: "Fill the saved password for \(only.username)") {
                Task { await fill(only) }
            }
        } else {
            Menu {
                ForEach(matches) { credential in
                    Button(credential.username.isEmpty ? "(no username)" : credential.username) {
                        Task { await fill(credential) }
                    }
                }
            } label: {
                icon
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24, height: 24)
            .help("Fill a saved password")
        }
    }

    private func button(help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { icon }
            .buttonStyle(.plain)
            .frame(width: 24, height: 24)
            .help(help)
    }

    private var icon: some View {
        Image(systemName: iconName)
            .font(.system(size: 12, weight: .medium))
            // Green only briefly, as an acknowledgement: a fill is otherwise
            // invisible when the page renders dots.
            .foregroundStyle(status == .filled ? Color.green : Color.secondary)
            .contentShape(Rectangle())
            .accessibilityLabel("Fill saved password")
            // A refusal has to *say* something: a fill that quietly does nothing
            // is indistinguishable from a fill that worked, since the page shows
            // dots either way. Dismissible, and it goes on its own after a while.
            .popover(isPresented: failureBinding, arrowEdge: .bottom) {
                // A fixed width, not a max: a popover takes its size from the
                // content, and a `Text` given only a maximum width collapses to
                // the anchor button's 24 pt and truncates the sentence to
                // nothing. Found by reading it on screen.
                Text(failureMessage ?? "")
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 220, alignment: .leading)
                    .padding(12)
            }
    }

    /// A key, a *locked* key when the vault is locked, a filled key on success.
    /// The locked state is shown rather than hidden so the click that follows is
    /// not a surprise prompt.
    private var iconName: String {
        if status == .filled { return "key.fill" }
        return store.isVaultLocked ? "key.slash" : "key"
    }

    private var failureMessage: String? {
        if case .failed(let message) = status { return message }
        return nil
    }

    private var failureBinding: Binding<Bool> {
        .init(
            get: { failureMessage != nil },
            set: { if !$0 { status = nil } }
        )
    }

    private func fill(_ credential: Credential) async {
        guard let paneID else { return }
        let outcome = await store.fillCredential(
            credential.id, intoPane: paneID, inSpace: windowState.activeSpaceID
        )
        switch outcome {
        case .filled:
            status = .filled
            // Fades back to the plain key; the acknowledgement is a moment, not
            // a mode.
            try? await Task.sleep(for: .seconds(2))
            if status == .filled { status = nil }
        case .vaultLocked:
            status = .failed(
                "Chord did not fill anything — the vault stayed locked because "
                    + "authentication was cancelled."
            )
        case .originMismatch:
            status = .failed("This page is no longer the site that password belongs to")
        case .fieldsUnavailable:
            status = .failed("The login fields are no longer on the page")
        case .noPane:
            status = nil
        }
    }
}
