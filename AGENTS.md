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
make run      # build, bundle and open; on main build/Bosun.app, on any other branch build/Bosun-test.app
make stop     # quit the copy of this checkout and branch; `make stop-all` quits every Bosun
```

Two Bosuns. The main Bosun is `build/Bosun.app` of the main checkout, built from `main`; it runs all day and is restarted only when asked. On any other branch, in the main checkout or in a worktree, `make run` builds and launches `build/Bosun-test.app`, a second instance beside the main one for trying the change. Start and restart that one freely, without asking, and `make stop` it when the test is done: two Bosuns on one agent-deck both notify and both attach. Never put the main Bosun on a branch's build.

Driving the test copy from an agent. Agents run in agent-deck's tmux, which the main Bosun started, so macOS checks the main Bosun's Accessibility and Screen Recording grants when an agent runs `osascript` or `screencapture`; the test copy never needs a grant of its own. `make bundle` signs ad hoc, so a grant matches one build of the main Bosun only. After it is rebuilt, System Settings still shows Bosun on, yet `osascript` fails with `-25211`, captures fail, and tccd logs `Failed to match existing code requirement for subject com.bosun.Bosun`; switching it off and on keeps the old build. Then run `tccutil reset Accessibility com.bosun.Bosun && tccutil reset ScreenCapture com.bosun.Bosun`, trigger both prompts, and ask the user to switch Bosun on in both lists. If captures still fail once Accessibility works, ask the user to check Screen & System Audio Recording before asking to restart the main Bosun.

```sh
swift - <<'EOF'
import ApplicationServices
import CoreGraphics
print("accessibility:", AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary), "screen-capture:", CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess())
EOF
```

Both copies run as process `Bosun` with bundle identifier `com.bosun.Bosun`, and System Events resolves a process by name, so `osascript` cannot address the test copy while both run. Drive it through the Accessibility API by PID instead: `AXUIElementCreateApplication(pid)` to read and press elements, and `CGEvent.postToPid(pid)` for keys, after `NSRunningApplication(processIdentifier:)?.activate()` and a check that `NSWorkspace.shared.frontmostApplication` is the test copy; keys posted to an app in the background are dropped. They share `UserDefaults` too: note the keys a test changes (`collapsedGroups`, `sidebarTab`, `sidebar*`) and put them back afterwards.

CI (`.github/workflows/ci.yml`) runs build and test on `macos-26` for PRs and main.

## Things not obvious from the code

- tmux's first window of a session runs the agent; Bosun attaches through its own grouped "view" sessions (`ViewSession`) so switching windows does not move other clients.
- Session status comes from agent-deck's event bus (`events follow`) with a periodic `list` reconcile; omp's pane titles are polled for turn ends and questions.
- Comments say why a line exists, in full sentences; no "what" comments, no caller lists.
- Never amend or force-push.
