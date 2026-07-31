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
        Image(systemName: status == .filled ? "key.fill" : "key")
            .font(.system(size: 12, weight: .medium))
            // Green only briefly, as an acknowledgement: a fill is otherwise
            // invisible when the page renders dots.
            .foregroundStyle(status == .filled ? Color.green : Color.secondary)
            .contentShape(Rectangle())
            .accessibilityLabel("Fill saved password")
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
        case .originMismatch:
            status = .failed("This page is no longer the site that password belongs to")
        case .fieldsUnavailable:
            status = .failed("The login fields are no longer on the page")
        case .noPane:
            status = nil
        }
    }
}
