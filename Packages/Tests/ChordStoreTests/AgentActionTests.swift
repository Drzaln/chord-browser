import ChordCore
import ChordEngine
import ChordMCP
import ChordTestSupport
import Foundation
import Testing

@testable import ChordStore

@Suite("Agent action policy")
struct AgentActionPolicyTests {
    @Test("Risky labels match whole words, in English and Indonesian")
    func riskyWords() {
        #expect(AgentActionPolicy.riskyPhrase(in: "Place order") == "place order")
        #expect(AgentActionPolicy.riskyPhrase(in: "Delete account") == "delete")
        #expect(AgentActionPolicy.riskyPhrase(in: "Bayar sekarang") == "bayar")
        #expect(AgentActionPolicy.riskyPhrase(in: "Next page") == nil)
        // Whole words: "Paypal" and "postcode" are not "pay" and "post".
        #expect(AgentActionPolicy.riskyPhrase(in: "Paypal postcode") == nil)
    }

    @Test("Sign-in and POST forms ask; a GET search does not")
    func forms() {
        #expect(AgentActionPolicy.reason(submitting: ["method": "post", "has_password": true]) != nil)
        #expect(AgentActionPolicy.reason(submitting: ["method": "post", "is_search": false]) != nil)
        #expect(AgentActionPolicy.reason(submitting: ["method": "get", "is_search": true, "submit_text": "Search"]) == nil)
        #expect(AgentActionPolicy.reason(submitting: ["method": "get", "submit_text": "Buy now"]) != nil)
        #expect(AgentActionPolicy.reason(submitting: nil) == nil)
    }

    @Test("A filled password anywhere on the page makes any click or submit ask")
    func filledPassword() {
        // Google-style: no <form>, a plain "Next" button, a password typed in.
        #expect(AgentActionPolicy.reason(clicking: ["name": "Next", "password_filled": true]) != nil)
        #expect(AgentActionPolicy.reason(typingAndSubmitting: ["name": "Code", "password_filled": true]) != nil)
        #expect(AgentActionPolicy.reason(clicking: ["name": "Next", "password_filled": false]) == nil)
    }

    @Test("A click asks for a risky label or a submitting button, not for a plain link")
    func clicks() {
        #expect(AgentActionPolicy.reason(clicking: ["name": "Next page", "is_submit": false]) == nil)
        #expect(AgentActionPolicy.reason(clicking: ["name": "Send", "is_submit": false]) != nil)
        #expect(AgentActionPolicy.reason(clicking: [
            "name": "Continue", "is_submit": true, "form": ["method": "post"],
        ]) != nil)
    }
}

/// Phase 2's tools against the fake engine: permission, confirmation, effects.
@Suite("Agent access — act tools", .serialized)
@MainActor
struct AgentActionTests {
    let work = Space(id: UUID(), name: "Work", sortIndex: 0)
    let reading = Space(id: UUID(), name: "Reading", sortIndex: 1)

    final class Answers {
        var prompts: [AgentActionPrompt] = []
        var answer = true
    }

    /// `work` allows acting, `reading` is read-only. The engine answers
    /// describe with `element` and anything else with ok.
    private func makeStore(element: JSONValue = ["ok": true, "name": "Next", "host": "work.example"])
        -> (TabStore, FakeWebEngine, Tab, Tab, Answers)
    {
        let engine = FakeWebEngine()
        let workTab = TabBuilder().space(work.id).url("https://work.example/").build()
        let readTab = TabBuilder().space(reading.id).url("https://news.example/").build()
        let store = TabStore(engine: engine, repository: FakeTabRepository(stored: []), clock: FixedClock())
        store.preferenceStore = InMemoryPreferenceStore()
        store.agentSpaceIDs = []
        store.agentActSpaceIDs = []
        store.spaces = [work, reading]
        store.tabs = [workTab, readTab]
        store.primaryWindow.activeSpaceID = work.id
        store.agentSocketPath = "/tmp/chord-act-\(getpid())-\(UUID().uuidString.prefix(6))/s.sock"
        store.agentAccessEnabled = true
        store.setAgentAccessLevel(.act, for: work.id)
        store.setAgentAccessLevel(.read, for: reading.id)
        _ = engine.surface(for: workTab.focusedPane, in: work)
        _ = engine.surface(for: readTab.focusedPane, in: reading)

        let describe = String(decoding: try! JSONEncoder().encode(element), as: UTF8.self)
        engine.agentResponder = { request, _ in
            switch request {
            case .describe: describe
            case .type: #"{"ok":true,"value":"typed"}"#
            case .findText: #"{"ok":true,"found":true}"#
            default: #"{"ok":true}"#
            }
        }
        let answers = Answers()
        store.agentConfirmationPresenter = { prompt in
            answers.prompts.append(prompt)
            return answers.answer ? .allow : .deny
        }
        return (store, engine, workTab, readTab, answers)
    }

    private func call(_ store: TabStore, _ name: String, _ arguments: [String: JSONValue]) async -> MCPToolResult {
        await AgentTools(store: store).callTool(name: name, arguments: arguments)
    }

    private func text(_ result: MCPToolResult) -> String {
        result.content.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined()
    }

    private func clicks(_ engine: FakeWebEngine) -> Int {
        engine.agentRequests.filter { if case .click = $0.0 { true } else { false } }.count
    }

    @Test("Levels: act implies read, off clears both, and both persist")
    func levels() {
        let (store, _, _, _, _) = makeStore()
        defer { store.agentAccessEnabled = false }
        #expect(store.agentAccessLevel(for: work.id) == .act)
        #expect(store.agentAccessLevel(for: reading.id) == .read)
        store.setAgentAccessLevel(.off, for: work.id)
        #expect(store.agentAccessLevel(for: work.id) == .off)
        #expect(!store.agentActSpaceIDs.contains(work.id))
        #expect(Preferences.loadAgentActSpaceIDs(store.preferenceStore).isEmpty)
    }

    @Test("A read-only Space refuses every act tool, with how to allow it")
    func readOnlyRefuses() async {
        let (store, engine, _, readTab, _) = makeStore()
        defer { store.agentAccessEnabled = false }
        let tab: [String: JSONValue] = ["tab_id": .string(readTab.id.uuidString)]
        for (name, extra) in [
            ("click", ["ref": "e1"]), ("type", ["ref": "e1", "text": "x"]), ("list_elements", [:]),
            ("navigate", ["url": "https://x.example"]), ("switch_tab", [:]), ("close_tab", [:]),
        ] as [(String, [String: JSONValue])] {
            let result = await call(store, name, tab.merging(extra) { a, _ in a })
            #expect(result.isError, "\(name) must refuse")
            #expect(text(result).contains("read-only"))
        }
        #expect(engine.agentRequests.isEmpty)
        #expect(store.tabs.contains { $0.id == readTab.id })
        // Waiting changes nothing, so read access is enough for it.
        #expect(!(await call(store, "wait_for", tab)).isError)
    }

    @Test("A plain click goes ahead without asking")
    func plainClick() async {
        let (store, engine, workTab, _, answers) = makeStore()
        defer { store.agentAccessEnabled = false }
        let result = await call(store, "click", ["tab_id": .string(workTab.id.uuidString), "ref": "e1"])
        #expect(!result.isError)
        #expect(answers.prompts.isEmpty)
        #expect(clicks(engine) == 1)
    }

    @Test("A risky click asks; denied, it never happens")
    func deniedClick() async {
        let (store, engine, workTab, _, answers) = makeStore(
            element: ["ok": true, "name": "Place order", "host": "shop.example", "is_submit": false]
        )
        defer { store.agentAccessEnabled = false }
        answers.answer = false
        let result = await call(store, "click", ["tab_id": .string(workTab.id.uuidString), "ref": "e1"])
        #expect(result.isError)
        #expect(text(result).contains("did not allow"))
        #expect(answers.prompts.first?.host == "shop.example")
        #expect(answers.prompts.first?.spaceName == "Work")
        #expect(clicks(engine) == 0)
    }

    @Test("A risky click the user allows happens")
    func allowedClick() async {
        let (store, engine, workTab, _, answers) = makeStore(
            element: ["ok": true, "name": "Send", "host": "mail.example"]
        )
        defer { store.agentAccessEnabled = false }
        let result = await call(store, "click", ["tab_id": .string(workTab.id.uuidString), "ref": "e1"])
        #expect(!result.isError)
        #expect(answers.prompts.count == 1)
        #expect(clicks(engine) == 1)
    }

    @Test("With nobody to ask, a risky action is refused")
    func noPresenterMeansNo() async {
        let (store, engine, workTab, _, _) = makeStore(element: ["ok": true, "name": "Delete"])
        defer { store.agentAccessEnabled = false }
        store.agentConfirmationPresenter = nil
        #expect(await call(store, "click", ["tab_id": .string(workTab.id.uuidString), "ref": "e1"]).isError)
        #expect(clicks(engine) == 0)
    }

    @Test("Access revoked while the user decides stops the action")
    func revokedDuringConfirmation() async {
        let (store, engine, workTab, _, _) = makeStore(element: ["ok": true, "name": "Buy"])
        defer { store.agentAccessEnabled = false }
        store.agentConfirmationPresenter = { [work] _ in
            store.setAgentAccessLevel(.read, for: work.id)
            return .allow
        }
        let result = await call(store, "click", ["tab_id": .string(workTab.id.uuidString), "ref": "e1"])
        #expect(result.isError)
        #expect(clicks(engine) == 0)
    }

    @Test("Typing into a password field is refused before anyone is asked")
    func passwordRefused() async {
        let (store, engine, workTab, _, answers) = makeStore(
            element: ["ok": true, "name": "Password", "is_password": true, "form": ["has_password": true]]
        )
        defer { store.agentAccessEnabled = false }
        let result = await call(store, "type", [
            "tab_id": .string(workTab.id.uuidString), "ref": "e1", "text": "x", "submit": true,
        ])
        #expect(result.isError)
        #expect(text(result).contains("password"))
        #expect(answers.prompts.isEmpty)
        #expect(!engine.agentRequests.contains { if case .type = $0.0 { true } else { false } })
    }

    @Test("Typing without submit never asks; submitting a POST form does")
    func typeAndSubmit() async {
        let (store, engine, workTab, _, answers) = makeStore(
            element: ["ok": true, "name": "Comment", "form": ["method": "post", "is_search": false]]
        )
        defer { store.agentAccessEnabled = false }
        let args: [String: JSONValue] = ["tab_id": .string(workTab.id.uuidString), "ref": "e1", "text": "hi"]
        #expect(!(await call(store, "type", args)).isError)
        #expect(answers.prompts.isEmpty)

        var submit = args
        submit["submit"] = true
        #expect(!(await call(store, "type", submit)).isError)
        #expect(answers.prompts.map(\.action) == ["submit"])
        #expect(engine.agentRequests.last?.0 == .type(ref: "e1", text: "hi", clear: true, submit: true))
    }

    @Test("open_url opens in an acting Space and refuses non-web schemes")
    func openURL() async {
        let (store, _, _, _, _) = makeStore()
        defer { store.agentAccessEnabled = false }
        let before = store.tabs.count
        let result = await call(store, "open_url", ["url": "https://docs.example/page"])
        #expect(!result.isError)
        #expect(store.tabs.count == before + 1)
        let opened = store.tabs.first { $0.focusedPane.url.host() == "docs.example" }
        #expect(opened?.spaceID == work.id)
        #expect(store.primaryWindow.selectedTabID == opened?.id)

        for bad in ["file:///etc/passwd", "javascript:alert(1)", "chord-offline://x", "not a url"] {
            #expect(await call(store, "open_url", ["url": .string(bad)]).isError, "\(bad)")
        }
        #expect(await call(store, "open_url", [
            "url": "https://x.example", "space_id": .string(reading.id.uuidString),
        ]).isError)
    }

    @Test("A background open loads the tab without selecting it")
    func backgroundOpen() async {
        let (store, engine, workTab, _, _) = makeStore()
        defer { store.agentAccessEnabled = false }
        store.primaryWindow.selectedTabID = workTab.id
        _ = await call(store, "open_url", ["url": "https://bg.example/", "background": true])
        let opened = store.tabs.first { $0.focusedPane.url.host() == "bg.example" }
        #expect(opened != nil)
        #expect(store.primaryWindow.selectedTabID == workTab.id)
        #expect(engine.hasLiveView(paneID: opened!.focusedPaneID))
    }

    @Test("navigate loads a URL and records it on the pane")
    func navigate() async {
        let (store, engine, workTab, _, _) = makeStore()
        defer { store.agentAccessEnabled = false }
        let result = await call(store, "navigate", [
            "tab_id": .string(workTab.id.uuidString), "url": "https://work.example/next",
        ])
        #expect(!result.isError)
        #expect(store.tabs.first { $0.id == workTab.id }?.focusedPane.url.path() == "/next")
        #expect(engine.loadedURLs.last?.1.path() == "/next")
        #expect(await call(store, "navigate", ["tab_id": .string(workTab.id.uuidString), "url": "ftp://x"]).isError)
    }

    @Test("switch_tab shows the tab; close_tab closes it")
    func switchAndClose() async {
        let (store, _, workTab, _, _) = makeStore()
        defer { store.agentAccessEnabled = false }
        let other = TabBuilder().space(work.id).url("https://other.example/").build()
        store.tabs.append(other)

        #expect(!(await call(store, "switch_tab", ["tab_id": .string(other.id.uuidString)])).isError)
        #expect(store.primaryWindow.selectedTabID == other.id)

        #expect(!(await call(store, "close_tab", ["tab_id": .string(workTab.id.uuidString)])).isError)
        #expect(!store.tabs.contains { $0.id == workTab.id })
    }

    @Test("wait_for waits out a navigation that starts just after a click")
    func waitForSettles() async {
        let (store, engine, workTab, _, _) = makeStore()
        defer { store.agentAccessEnabled = false }
        let pane = workTab.focusedPaneID
        engine.snapshots[pane] = PaneSnapshot(url: URL(string: "https://work.example/old"), isLoading: false)
        // The click's navigation begins 300 ms later and finishes at 700 ms.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            engine.snapshots[pane] = PaneSnapshot(url: URL(string: "https://work.example/new"), isLoading: true)
            try? await Task.sleep(for: .milliseconds(400))
            engine.snapshots[pane] = PaneSnapshot(url: URL(string: "https://work.example/new"), isLoading: false)
        }
        let result = await call(store, "wait_for", ["tab_id": .string(workTab.id.uuidString), "timeout_seconds": 5])
        #expect(!result.isError)
        #expect(text(result).contains("/new"))
    }

    @Test("wait_for finds text on a loaded page")
    func waitFor() async {
        let (store, _, workTab, _, _) = makeStore()
        defer { store.agentAccessEnabled = false }
        let result = await call(store, "wait_for", [
            "tab_id": .string(workTab.id.uuidString), "text": "Welcome", "timeout_seconds": 1,
        ])
        #expect(!result.isError)
        #expect(text(result).contains("Welcome"))
    }

    @Test("Element labels are marked untrusted")
    func listElementsIsLabelled() async {
        let (store, _, workTab, _, _) = makeStore()
        defer { store.agentAccessEnabled = false }
        let result = await call(store, "list_elements", ["tab_id": .string(workTab.id.uuidString)])
        #expect(text(result).contains("come from the website"))
    }

    @Test("Each action shows on the indicator; a denial does too")
    func activityIsShown() async {
        let (store, _, workTab, _, answers) = makeStore(
            element: ["ok": true, "name": "Search", "host": "youtube.com"]
        )
        defer { store.agentAccessEnabled = false }
        #expect(!store.showsAgentIndicator)
        _ = await call(store, "click", ["tab_id": .string(workTab.id.uuidString), "ref": "e1"])
        #expect(store.agentActivity == "Agent clicked “Search” on youtube.com")
        #expect(store.showsAgentIndicator)

        let (risky, _, riskyTab, _, riskyAnswers) = makeStore(
            element: ["ok": true, "name": "Delete", "host": "mail.example"]
        )
        defer { risky.agentAccessEnabled = false }
        riskyAnswers.answer = false
        _ = await call(risky, "click", ["tab_id": .string(riskyTab.id.uuidString), "ref": "e1"])
        #expect(risky.agentActivity?.contains("denied") == true)
        _ = answers
    }

    @Test("The indicator lingers after the last agent hangs up, and Disconnect clears it")
    func indicatorLingers() {
        let (store, _, _, _, _) = makeStore()
        defer { store.agentAccessEnabled = false }
        store.agentConnectionsChanged(to: 1)
        #expect(store.showsAgentIndicator)
        store.agentConnectionsChanged(to: 0)
        #expect(store.showsAgentIndicator)  // lingering
        #expect(store.agentLingerUntil != nil)
        store.disconnectAgents()
        #expect(!store.showsAgentIndicator)
        #expect(store.agentActivity == nil)
    }

    @Test("Long page titles are trimmed for the indicator's one line")
    func shortTitles() {
        #expect(AgentTools.short("abc") == "abc")
        #expect(AgentTools.short(String(repeating: "x", count: 60)).count == 40)
        #expect(AgentTools.short("two\nlines") == "two lines")
    }

    @Test("tools/list offers the act tools, flagged as not read-only")
    func toolList() async {
        let (store, _, _, _, _) = makeStore()
        defer { store.agentAccessEnabled = false }
        let tools = await AgentTools(store: store).listTools()
        let names = Set(tools.map(\.name))
        #expect(names.isSuperset(of: ["click", "type", "open_url", "navigate", "switch_tab", "close_tab", "wait_for"]))
        #expect(tools.first { $0.name == "click" }?.readOnly == false)
        #expect(tools.first { $0.name == "list_elements" }?.readOnly == true)
    }
}
