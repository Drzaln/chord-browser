# 027 — Chord as a local MCP server, reached through its own executable

**Status:** accepted (0mu phase 1, 2026-11-05)

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
  Disconnect. Settings → Agents shows the same.
- **Layering.** `ChordMCP` (Foundation + Darwin) knows JSON and tool names only.
  `ChordStore` (`TabStore+Agent`) supplies the tools. `ChordEngine` adds
  `agentPageContent` and `agentScreenshot`.

## Consequences

- Phase 1 is read-only: `list_spaces`, `list_tabs`, `read_page`, `screenshot`.
  Navigation and input (0mu.2) need a separate "act" permission and confirmation
  for destructive actions. `eval_js` (0mu.3) needs its own toggle.
- The helper path is the running build's executable. A dev build and the
  installed app are different executables, so a client set up for one is
  refused by the other. Settings shows the command for the build in use.
- A crash leaves a stale socket file. The next start finds nobody listening
  behind it and replaces it. A live listener (a second Chord) is refused.
