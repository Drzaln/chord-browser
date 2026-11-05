# 027 — Chord as a local MCP server, reached through its own executable

**Status:** accepted (0mu phase 1, 2026-11-05; phase 2 added the same day)

## Context

Agents such as Claude Code can drive a browser over the Model Context Protocol.
Headless browsers lack what makes Chord useful: the user's logged-in Spaces,
extensions and content blocking. Chord should be an MCP **server** that local
agents connect to. It does not become an MCP client with a chat UI of its own.

MCP clients start a server as a child process and talk to it over stdio, or
connect to an HTTP endpoint. Chord is already running and owns the web views,
so it cannot be the child an agent starts.

## Decision

- **Transport.** The running app listens on a Unix-domain socket,
  `~/Library/Application Support/Chord/MCP/chord.sock`, using stdio's framing
  (one JSON-RPC message per line). The MCP client starts **Chord's own
  executable with `--mcp-stdio`**, which copies stdio to the socket and back
  (`MCPStdioBridge`). That check runs in `ChordMain` before AppKit starts. The
  helper therefore has no MCP logic to keep in step, and it is not a second
  binary: the Xcode project gains no target and the release pipeline does not
  change.
- **No network listener.** There is no TCP or HTTP endpoint at all.
- **Who may connect.** The socket's directory is 0700 and the socket itself 0600
  (bound under `umask 077`). Each peer is identified with `LOCAL_PEERCRED` and
  `LOCAL_PEERPID`, and must be the same user running Chord's own executable
  (`proc_pidpath`, realpath'd). Any other program has to go through the helper,
  which an MCP client runs only because the user configured it. A
  code-signature check was left out: it would pull Security into a new target
  and adds nothing against a same-user attacker, who can already read the
  user's files.
- **Off by default, scoped per Space.** `agentAccessEnabled` starts false, and
  `agentSpaceIDs` starts empty, so turning access on shares nothing until a
  Space is ticked. Private Spaces are never shared. A tab outside the shared
  Spaces is answered exactly like a tab that does not exist.
- **Nothing secret is reachable.** No tool touches the vault, cookies or the
  password monitor's content world. Page text is read in its own
  `WKContentWorld` (`chord.agent`) from `innerText`, which carries no form-field
  values.
- **Untrusted output is labelled.** `read_page` wraps the text in
  BEGIN/END markers and says it was written by the website. The server's
  `instructions` say the same. This is the prompt-injection channel; phase 2's
  act tools must be built assuming page text is hostile.
- **Never builds a web view.** Reading an unloaded tab reports it rather than
  loading it, which keeps lazy restore (6.2) intact. A screenshot works only for
  a pane on screen, since detached views snapshot blank.
- **Visible.** While any agent is connected, every window shows a pill with
  Disconnect. Settings → Agents shows the same. The pill also says what the
  agent last did ("Agent clicked “Search” on youtube.com") and pulses while
  that is fresh. It lingers for 5 s after the last action or disconnect, so a
  burst of short connections cannot come and go unseen; found in testing,
  where one-shot clients made it flash for under a second.
- **Layering.** `ChordMCP` (Foundation + Darwin) knows JSON and tool names only.
  `ChordStore` (`TabStore+Agent`) supplies the tools. `ChordEngine` adds
  `agentPageContent` and `agentScreenshot`.

## Consequences

- Phase 1 is read-only: `list_spaces`, `list_tabs`, `read_page`, `screenshot`.
  Phase 2 adds acting (below). `eval_js` (0mu.3) needs its own toggle.
- The helper path is the running build's executable. A dev build and the
  installed app are different executables, so a client set up for one is
  refused by the other. Settings shows the command for the build in use.
- A crash leaves a stale socket file. The next start finds nobody listening
  behind it and replaces it. A live listener (a second Chord) is refused.

## Phase 2: acting (0mu.2)

- **A third access level.** Each Space is Off, Read or Read & Act
  (`agentActSpaceIDs`, always a subset of the shared Spaces in effect). Acting
  in a read-only Space returns a refusal that names the setting to change.
- **Tools:** `list_elements`, `click`, `type`, `scroll`, `wait_for`,
  `open_url`, `navigate`, `switch_tab`, `close_tab`. URLs must be http(s).
- **Fixed scripts, not code.** Each action is an `AgentPageRequest` case
  running one script (`AgentPageScript`) in the agent world. The store never
  sends JavaScript to a page. Arbitrary JavaScript stays in 0mu.3.
- **Refs live in the agent world.** `list_elements` hands out `e<n>` refs held
  in a `Map` of `WeakRef`s in that world, never written to the DOM, so a page
  cannot read, forge or move them. A detached element reads as a stale ref.
- **Typing uses the prototype value setter**, as the password filler does, so
  React-style value trackers see the change. Password fields are refused, both
  in the script and in the store before anyone is asked.
- **Confirmation (`AgentActionPolicy`).** Chord asks in a native sheet before:
  - submitting a form with a password field;
  - any click or submit while a password field anywhere on the page has a
    value. Script-driven sign-ins (Google's "Next", no `<form>`) slip past
    the form rules, and this catches them;
  - submitting a POST form that isn't a search;
  - anything whose label contains a risky word (buy, pay, send, delete, …,
    plus the Indonesian equivalents).

  Deny is the default button, and two minutes without an answer counts as a
  no. Labels come from the page, so the word list is best effort. The
  POST-form rule holds whatever the page calls its button. Access is
  re-checked after the user answers.
- **Synthetic events.** Clicks are dispatched DOM events plus `el.click()`,
  so `isTrusted` is false. A site that insists on trusted input will ignore
  them, which is acceptable: it fails closed.
- **`wait_for` settles.** A page must stay idle for 800 ms before it counts as
  loaded. A click's navigation starts a beat after the click returns, and
  without the settle the old page answered "loaded" (found live on YouTube's
  Sign in).
- **Lazy restore still holds**, except where the agent asks for loading:
  `open_url` with `background` and `navigate` on an unloaded tab build the
  view, because that is what was requested.
