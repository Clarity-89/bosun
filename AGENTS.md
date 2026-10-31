# Bosun

macOS app over [agent-deck](https://github.com/asheshgoplani/agent-deck): lists its sessions, attaches the selected one in an embedded libghostty terminal, notifies on agent turns, and shows a GitHub inbox. Swift 6.2, SwiftUI + AppKit, SwiftPM, macOS 26 only. No Xcode project.

## Layout

- `Sources/BosunCore`: no UI. agent-deck CLI (`AgentDeckCLI`, `run([...])` for `--json` commands, `tmux([...])` for the few things agent-deck has no command for), models decoded from `list --json`, GitHub via `gh api graphql`, omp log and pane parsing, `Subprocess`.
- `Sources/BosunTerminal`: libghostty wrapper (`TerminalPane`). `Vendored/` is adapted from Calyx, MIT; keep its header comments.
- `Sources/Bosun`: the app. `DeckModel` (`@Observable`, `@MainActor`) owns state and runs every action through `run(label) { ... }`, which puts failures in `lastError` for `StatusNotices`. Views are split by feature: `MainWindowView`, `SessionActions`, `InboxView`, `SideTerminalsView`, `AttentionCenter`.
- `Tests/BosunCoreTests` and `Tests/BosunTests`: Swift Testing (`@Suite`, `@Test`), fixtures trimmed from real agent-deck, tmux and GitHub output. The terminal has no tests; it needs a GUI session.

## Build and run

```sh
make vendor   # libghostty (141 MB) into gitignored Vendor/, once
swift build && swift test
make run      # release bundle in build/Bosun.app, then open; quits this checkout's running copy first
make stop     # quit this checkout's copy; `make stop-all` quits every Bosun
```

One Bosun runs all day: the main checkout's, built from `main`, and the main checkout stays on `main`. A branch is tested from its worktree, where `make run` builds and launches that worktree's own `build/Bosun.app` beside the main one. Quit it with `make stop` when the test is done: two Bosuns on one agent-deck both notify and both attach, and the one left running is rarely the one with the change.

CI (`.github/workflows/ci.yml`) runs build and test on `macos-26` for PRs and main.

## Things not obvious from the code

- tmux's first window of a session runs the agent; Bosun attaches through its own grouped "view" sessions (`ViewSession`) so switching windows does not move other clients.
- Session status comes from agent-deck's event bus (`events follow`) with a periodic `list` reconcile; omp's pane titles are polled for turn ends and questions.
- Comments say why a line exists, in full sentences; no "what" comments, no caller lists.
- Never amend or force-push.
