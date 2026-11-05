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
            connectSection
        }
    }

    @ViewBuilder
    private var accessSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Local Agents (MCP)").font(.system(size: 13, weight: .semibold))
            Text(
                "Lets AI agents on this Mac, such as Claude Code, list your tabs, read "
                    + "pages and take screenshots in the Spaces you pick below. Only "
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
                "An agent sees only these Spaces. Page text comes from websites, and a "
                    + "page can try to give an agent instructions, so a Space with your "
                    + "bank or email is best left out. Private Spaces are never shared."
            )
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            ForEach(store.spaces.filter { !$0.isPrivate }) { space in
                Toggle(
                    space.name,
                    isOn: Binding(
                        get: { store.agentSpaceIDs.contains(space.id) },
                        set: { store.setAgentAccess($0, for: space.id) }
                    )
                )
                .toggleStyle(.checkbox)
            }
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

/// "● An agent is using Chord — Disconnect", at the foot of every window while
/// one is connected, in the style of the extension recording pill.
struct AgentConnectedPill: View {
    let count: Int
    let onDisconnect: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(nsColor: .systemPurple))
                .frame(width: 7, height: 7)
            Text(count == 1 ? "An agent is connected to Chord" : "\(count) agents are connected to Chord")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 12)
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
        .padding(.leading, 14)
        .padding(.trailing, 7)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent connected")
    }
}
