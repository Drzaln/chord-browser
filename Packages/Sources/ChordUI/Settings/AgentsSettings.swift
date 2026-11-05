import AppKit
import ChordCore
import ChordStore
import SwiftUI

/// The Agents section of the settings sheet (0mu): lets local AI agents use
/// Chord over MCP. Off by default; once on, an agent sees only the Spaces
/// ticked here, never a private one.
struct AgentsSettings: View {
    @Bindable var store: TabStore
    @State private var copied: String?

    /// Chord's own executable, which an MCP client runs with `--mcp-stdio`.
    private var helperPath: String {
        Bundle.main.executablePath ?? "/Applications/Chord.app/Contents/MacOS/Chord"
    }

    private var claudeCommand: String {
        "claude mcp add chord -- \"\(helperPath)\" \(AgentBridge.stdioFlag)"
    }

    private var jsonConfig: String {
        """
        "chord": {
          "command": "\(helperPath)",
          "args": ["\(AgentBridge.stdioFlag)"]
        }
        """
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            accessSection
            Divider()
            spacesSection
            Divider()
            scriptsSection
            Divider()
            connectSection
        }
    }

    @ViewBuilder
    private var accessSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Local Agents (MCP)").font(.system(size: 13, weight: .semibold))
            Text(
                "Lets AI agents on this Mac, such as Claude Code, use Chord in the "
                    + "Spaces you pick below. Only "
                    + "agents started on this Mac can connect, and nothing goes over the "
                    + "network. Agents never get passwords or cookies."
            )
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Toggle(
                "Allow local agents (MCP)",
                isOn: Binding(
                    get: { store.agentAccessEnabled },
                    set: { store.agentAccessEnabled = $0 }
                )
            )
            .toggleStyle(.checkbox)

            if let error = store.agentAccessError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if store.agentConnectionCount > 0 {
                HStack(spacing: 8) {
                    Label(
                        store.agentConnectionCount == 1
                            ? "1 agent connected" : "\(store.agentConnectionCount) agents connected",
                        systemImage: "dot.radiowaves.left.and.right"
                    )
                    .font(.system(size: 11))
                    Button("Disconnect") { store.disconnectAgents() }
                        .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private var spacesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Shared Spaces").font(.system(size: 13, weight: .semibold))
            Text(
                "Read lets an agent list tabs, read pages and take screenshots. Read & Act "
                    + "also lets it open tabs, navigate, click and type; Chord asks you before "
                    + "it signs in, submits a form that sends data, or clicks anything that "
                    + "reads like buying, paying, sending or deleting. It can never type into "
                    + "password fields. Pages can try to give an agent instructions, so a Space "
                    + "with your bank or email is best left Off. Private Spaces are never shared."
            )
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            ForEach(store.spaces.filter { !$0.isPrivate }) { space in
                HStack {
                    Text(space.name).lineLimit(1)
                    Spacer(minLength: 12)
                    Picker(
                        space.name,
                        selection: Binding(
                            get: { store.agentAccessLevel(for: space.id) },
                            set: { store.setAgentAccessLevel($0, for: space.id) }
                        )
                    ) {
                        Text("Off").tag(AgentAccessLevel.off)
                        Text("Read").tag(AgentAccessLevel.read)
                        Text("Read & Act").tag(AgentAccessLevel.act)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
        .disabled(!store.agentAccessEnabled)
        .opacity(store.agentAccessEnabled ? 1 : 0.5)
    }

    @ViewBuilder
    private var scriptsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("JavaScript").font(.system(size: 13, weight: .semibold))
            Text(
                "Lets agents run their own JavaScript in Read & Act Spaces. Chord shows "
                    + "you each script and asks before it runs. Scripts run apart from the "
                    + "page's own code and can't read cookies, site storage or password "
                    + "fields, but they can read anything else on the page."
            )
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Toggle(
                "Let agents run JavaScript",
                isOn: Binding(
                    get: { store.agentScriptsEnabled },
                    set: { store.agentScriptsEnabled = $0 }
                )
            )
            .toggleStyle(.checkbox)
        }
        .disabled(!store.agentAccessEnabled)
        .opacity(store.agentAccessEnabled ? 1 : 0.5)
    }

    @ViewBuilder
    private var connectSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connect an Agent").font(.system(size: 13, weight: .semibold))
            Text("Claude Code — run in Terminal:")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            snippet(claudeCommand)
            Text("Other MCP clients — add to the client's MCP servers config:")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            snippet(jsonConfig)
            Text("Chord must be running with agent access on for the agent to connect.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func snippet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(copied == text ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = text
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// The agent indicator, at the foot of every window (0mu): up while an agent
/// is connected and for a few seconds after it last acted or hung up, saying
/// what it just did. The dot pulses while the activity is fresh, so a quick
/// click is still noticed.
struct AgentConnectedPill: View {
    let count: Int
    let activity: String?
    let onDisconnect: () -> Void

    @State private var pulsing = false

    private var headline: String {
        if let activity { return activity }
        if count > 1 { return "\(count) agents are connected to Chord" }
        return count == 1 ? "An agent is connected to Chord" : "An agent was just using Chord"
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(nsColor: .systemPurple))
                .frame(width: 10, height: 10)
                .overlay(
                    Circle()
                        .stroke(Color(nsColor: .systemPurple), lineWidth: 2)
                        .scaleEffect(pulsing ? 2.2 : 1)
                        .opacity(pulsing ? 0 : 0.8)
                )
                .animation(
                    activity == nil ? .default : .easeOut(duration: 1).repeatForever(autoreverses: false),
                    value: pulsing
                )
            Text(headline)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: headline)
            Spacer(minLength: 12)
            if count > 0 {
                Button(action: onDisconnect) {
                    Text("Disconnect")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .padding(.horizontal, 11)
                        .frame(height: 22)
                        .background(.primary, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, count > 0 ? 7 : 14)
        .padding(.vertical, 7)
        .frame(minHeight: 36)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
        .fixedSize()
        .onAppear { pulsing = activity != nil }
        .onChange(of: activity) { _, new in
            // Restart the pulse on every new action, stop it once it fades.
            pulsing = false
            if new != nil { DispatchQueue.main.async { pulsing = true } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(headline)
    }
}

/// The yes/no an agent's consequential action waits on (0mu.2): a sheet on
/// the front Chord window, or a standalone alert when there is none. Brings
/// Chord forward, since the user is likely in the agent's terminal. No answer
/// within the timeout is a no.
@MainActor
public enum AgentConfirmation {
    public static func ask(
        _ prompt: AgentActionPrompt, timeout: Duration = .seconds(120)
    ) async -> AgentConfirmationAnswer {
        let alert = NSAlert()
        alert.alertStyle = .warning
        let site = prompt.host.isEmpty ? "this page" : prompt.host
        switch prompt.action {
        case "script": alert.messageText = "Allow an agent to run JavaScript on \(site)?"
        case "submit": alert.messageText = "Allow an agent to submit a form?"
        default: alert.messageText = "Allow an agent to click “\(prompt.target)”?"
        }
        var detail = prompt.action == "script" ? "In “\(prompt.target)”" : "On \(site)"
        if !prompt.spaceName.isEmpty { detail += " in \(prompt.spaceName)" }
        detail += ". Chord is asking because it \(prompt.reason)."
        if prompt.action == "submit", !prompt.target.isEmpty { detail += "\nField: \(prompt.target)" }
        alert.informativeText = detail

        if let script = prompt.script {
            // The whole script, scrollable and selectable: the user is
            // approving exactly this code, not a summary of it.
            let scroll = NSTextView.scrollableTextView()
            scroll.frame = NSRect(x: 0, y: 0, width: 440, height: 180)
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            if let text = scroll.documentView as? NSTextView {
                text.string = script
                text.isEditable = false
                text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                text.textContainerInset = NSSize(width: 4, height: 4)
            }
            alert.accessoryView = scroll
        }

        alert.addButton(withTitle: "Deny")
        alert.addButton(withTitle: "Allow")
        if prompt.offersAllowForSite { alert.addButton(withTitle: "Allow on \(site) Until Quit") }
        // Deny is the default: Return must never approve a purchase or a script.
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""

        NSApp.activate()
        let window = NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }

        let timer = Task { @MainActor in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            if let window, let sheet = window.attachedSheet, sheet == alert.window {
                window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
            } else {
                NSApp.abortModal()
            }
        }
        defer { timer.cancel() }

        let response: NSApplication.ModalResponse
        if let window {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        switch response {
        case .alertSecondButtonReturn: return .allow
        case .alertThirdButtonReturn: return prompt.offersAllowForSite ? .allowForSite : .deny
        default: return .deny
        }
    }
}
