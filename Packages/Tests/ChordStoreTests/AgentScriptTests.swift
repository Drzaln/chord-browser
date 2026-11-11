import ChordCore
import ChordEngine
import ChordMCP
import ChordTestSupport
import Foundation
import Testing

@testable import ChordStore

/// `eval_js` (0mu.3): its switch, its confirmation, and what it reports.
@Suite("Agent access — eval_js", .serialized)
@MainActor
struct AgentScriptTests {
    let work = Space(id: UUID(), name: "Work", sortIndex: 0)
    let reading = Space(id: UUID(), name: "Reading", sortIndex: 1)

    final class Asked {
        var prompts: [AgentActionPrompt] = []
        var answer: AgentConfirmationAnswer = .allow
    }

    private func makeStore() -> (TabStore, FakeWebEngine, Tab, Tab, Asked) {
        let engine = FakeWebEngine()
        let workTab = TabBuilder().space(work.id).url("https://work.example/").build()
        let readTab = TabBuilder().space(reading.id).url("https://news.example/").build()
        let store = TabStore(engine: engine, repository: FakeTabRepository(stored: []), clock: FixedClock())
        store.preferenceStore = InMemoryPreferenceStore()
        store.agentSpaceIDs = []
        store.agentActSpaceIDs = []
        store.agentScriptsEnabled = false
        store.spaces = [work, reading]
        store.tabs = [workTab, readTab]
        store.agentSocketPath = "/tmp/chord-js-\(getpid())-\(UUID().uuidString.prefix(6))/s.sock"
        store.agentAccessEnabled = true
        store.setAgentAccessLevel(.act, for: work.id)
        store.setAgentAccessLevel(.read, for: reading.id)
        _ = engine.surface(for: workTab.focusedPane, in: work)
        _ = engine.surface(for: readTab.focusedPane, in: reading)
        engine.agentEvalOutcome = .value(#"{"ok":1}"#)
        let asked = Asked()
        store.agentConfirmationPresenter = { prompt in
            asked.prompts.append(prompt)
            return asked.answer
        }
        return (store, engine, workTab, readTab, asked)
    }

    private func run(_ store: TabStore, _ tab: Tab, _ script: String = "return 1;") async -> MCPToolResult {
        await AgentTools(store: store).callTool(
            name: "eval_js", arguments: ["tab_id": .string(tab.id.uuidString), "script": .string(script)]
        )
    }

    private func text(_ result: MCPToolResult) -> String {
        result.content.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined()
    }

    @Test("Off by default, and refused while off")
    func offByDefault() async {
        #expect(Preferences.loadAgentScriptsEnabled(InMemoryPreferenceStore()) == false)
        let (store, engine, workTab, _, asked) = makeStore()
        defer { store.agentAccessEnabled = false }
        let result = await run(store, workTab)
        #expect(result.isError)
        #expect(text(result).contains("Settings → Agents"))
        #expect(engine.evaluatedScripts.isEmpty)
        #expect(asked.prompts.isEmpty)
    }

    @Test("Only in Read & Act Spaces, even with scripts on")
    func needsActSpace() async {
        let (store, engine, _, readTab, _) = makeStore()
        defer { store.agentAccessEnabled = false }
        store.agentScriptsEnabled = true
        #expect(await run(store, readTab).isError)
        #expect(engine.evaluatedScripts.isEmpty)
    }

    @Test("Each run shows the script and asks; a denial runs nothing")
    func asksWithScript() async {
        let (store, engine, workTab, _, asked) = makeStore()
        defer { store.agentAccessEnabled = false }
        store.agentScriptsEnabled = true
        asked.answer = .deny
        let result = await run(store, workTab, "return document.title;")
        #expect(result.isError)
        #expect(asked.prompts.first?.script == "return document.title;")
        #expect(asked.prompts.first?.offersAllowForSite == true)
        #expect(engine.evaluatedScripts.isEmpty)

        asked.answer = .allow
        #expect(!(await run(store, workTab)).isError)
        #expect(!(await run(store, workTab)).isError)
        #expect(asked.prompts.count == 3)  // asked every time
        #expect(engine.evaluatedScripts.count == 2)
    }

    @Test("Allow-for-site stops asking for that site until the switch goes off")
    func allowForSite() async {
        let (store, engine, workTab, _, asked) = makeStore()
        defer { store.agentAccessEnabled = false }
        store.agentScriptsEnabled = true
        asked.answer = .allowForSite
        _ = await run(store, workTab)
        _ = await run(store, workTab)
        #expect(asked.prompts.count == 1)
        #expect(engine.evaluatedScripts.count == 2)

        store.agentScriptsEnabled = false
        store.agentScriptsEnabled = true
        asked.answer = .allow
        _ = await run(store, workTab)
        #expect(asked.prompts.count == 2)
    }

    @Test("Results are labelled untrusted; failures say why")
    func outcomes() async {
        let (store, engine, workTab, _, asked) = makeStore()
        defer { store.agentAccessEnabled = false }
        store.agentScriptsEnabled = true
        asked.answer = .allowForSite

        let ok = await run(store, workTab)
        #expect(text(ok).contains("BEGIN RESULT"))
        #expect(text(ok).contains(#"{"ok":1}"#))
        #expect(text(ok).contains("not from the user"))

        engine.agentEvalOutcome = .passwordFilled
        #expect(text(await run(store, workTab)).contains("password is filled in"))
        engine.agentEvalOutcome = .timedOut
        #expect(text(await run(store, workTab)).contains("did not finish"))
        engine.agentEvalOutcome = .threw("TypeError: x")
        #expect(text(await run(store, workTab)).contains("TypeError"))

        engine.agentEvalOutcome = .value(String(repeating: "a", count: AgentTools.maxScriptOutput + 10))
        #expect(text(await run(store, workTab)).contains("Output cut"))
    }

    @Test("Empty or oversized scripts are refused before anyone is asked")
    func scriptLimits() async {
        let (store, engine, workTab, _, asked) = makeStore()
        defer { store.agentAccessEnabled = false }
        store.agentScriptsEnabled = true
        #expect(await run(store, workTab, "  ").isError)
        #expect(await run(store, workTab, String(repeating: "x", count: AgentTools.maxScriptCharacters + 1)).isError)
        #expect(asked.prompts.isEmpty)
        #expect(engine.evaluatedScripts.isEmpty)
    }

    @Test("Unshared after the yes: nothing runs")
    func revokedWhileAsking() async {
        let (store, engine, workTab, _, _) = makeStore()
        defer { store.agentAccessEnabled = false }
        store.agentScriptsEnabled = true
        store.agentConfirmationPresenter = { _ in
            store.agentScriptsEnabled = false
            return .allow
        }
        #expect(await run(store, workTab).isError)
        #expect(engine.evaluatedScripts.isEmpty)
    }
}
