import ChordEngine
import ChordStore
import SwiftUI

/// The DRM / streaming-capability diagnostics panel (non-spec: user-requested).
///
/// Netflix removed its secret menus (the debug overlay and
/// `netflix.com/testpatterns`) in 2023, so the only way to answer "does Chord's
/// engine + this display chain actually support what Netflix serves" is to probe
/// the engine directly. This panel reports the profiles Netflix uses — HEVC/HDR10
/// 4K, Dolby Vision, AC-3/E-AC-3/AAC — plus the HDCP ceiling of the current
/// display chain (a dock or non-HDCP adapter silently caps DRM streams to 720p)
/// and the media/EME errors the page has actually raised. It lives behind the
/// Develop menu, consistent with the Web Inspector dev-mode work.
struct DRMDiagnosticsView: View {
    @Bindable var store: TabStore
    @Bindable var windowState: WindowState

    @State private var diagnostics: MediaDiagnostics?
    @State private var isProbing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()

            if isProbing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Probing the engine…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let diagnostics {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        codecSection(diagnostics)
                        Divider()
                        hdcpSection(diagnostics)
                        Divider()
                        errorSection(diagnostics)
                    }
                    .padding(4)
                }
            } else {
                Text("No live page to probe. Open a tab first.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(width: 460, height: 520)
        .task { await probe() }
        .onChange(of: windowState.selectedTabID) { _, _ in Task { await probe() } }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("DRM Diagnostics").font(.system(size: 15, weight: .semibold))
                Text(
                    "What this browser's engine and display chain can actually play. "
                        + "Answers “can’t do it” vs “Netflix won’t serve it”."
                )
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { windowState.isDRMDiagnosticsPresented = false }
        }
    }

    @ViewBuilder
    private func codecSection(_ diagnostics: MediaDiagnostics) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Codec support").font(.system(size: 13, weight: .semibold))
            ForEach(diagnostics.codecs, id: \.mimeType) { probe in
                HStack(spacing: 8) {
                    Text(probe.label).font(.system(size: 12))
                    Spacer()
                    Text(status(for: probe))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(color(for: probe))
                }
            }
        }
    }

    @ViewBuilder
    private func hdcpSection(_ diagnostics: MediaDiagnostics) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("HDCP display chain").font(.system(size: 13, weight: .semibold))
            ForEach(diagnostics.hdcp, id: \.level) { probe in
                HStack(spacing: 8) {
                    Text("HDCP \(probe.level)").font(.system(size: 12))
                    Spacer()
                    Text(probe.available ? "available" : "unavailable")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(probe.available ? Color.green : Color.red)
                }
            }
            let highest = diagnostics.hdcp.filter(\.available).map(\.level).max()
            if let highest, Double(highest) ?? 0 < 2.2 {
                Text(
                    "Display chain caps at HDCP \(highest). DRM services may silently "
                        + "serve 720p — check docks and non-HDCP adapters."
                )
                .font(.system(size: 11)).foregroundStyle(.orange)
            } else if diagnostics.hdcp.contains(where: \.available) == false {
                Text("No HDCP-capable path reported — DRM playback will likely fail.")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func errorSection(_ diagnostics: MediaDiagnostics) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Playback errors").font(.system(size: 13, weight: .semibold))
            if let error = diagnostics.lastMediaError {
                Text("Last media error: \(error)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.red)
            } else {
                Text("No media error raised on this page.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text(
                diagnostics.hasEMESession
                    ? "DRM/EME is in use on this page."
                    : "No EME (encrypted media) session observed yet."
            )
            .font(.system(size: 11))
            .foregroundStyle(diagnostics.hasEMESession ? .primary : .secondary)
        }
    }

    private func status(for probe: CodecProbe) -> String {
        guard probe.isSupported else { return "no" }
        return probe.isPowerEfficient ? "hw" : "sw"
    }

    private func color(for probe: CodecProbe) -> Color {
        guard probe.isSupported else { return .red }
        return probe.isPowerEfficient ? .green : .orange
    }

    private func probe() async {
        isProbing = true
        defer { isProbing = false }
        diagnostics = await store.mediaDiagnostics(in: windowState)
    }
}
