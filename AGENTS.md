# Bosun

macOS app over [agent-deck](https://github.com/asheshgoplani/agent-deck): lists its sessions, attaches the selected one in an embedded libghostty terminal, notifies on agent turns, and shows a GitHub inbox. Swift 6.2, SwiftUI + AppKit, SwiftPM, macOS 26 only. No Xcode project.

## Layout

- `Sources/BosunCore`: no UI. `AgentDeck` is what the app asks of agent-deck and tmux; `AgentDeckCLI` answers it (`run([...])` for `--json` commands, `tmux([...])` for the few things agent-deck has no command for). Models decoded from `list --json`, GitHub via `gh api graphql` behind `GitHubClient`, omp log and pane parsing, `Subprocess`.
- `Sources/BosunTerminal`: libghostty wrapper (`TerminalPane`). `Vendored/` is adapted from Calyx, MIT; keep its header comments.
- `Sources/Bosun`: the app. `DeckModel` (`@Observable`, `@MainActor`) owns state and runs every action through `run(label) { ... }`, which puts failures in `lastError` for `StatusNotices`. It takes its agent-deck, GitHub and `Defaults` in `init`; `DeckModel.shared` is the app's, on the real ones. Views are split by feature: `MainWindowView`, `SessionActions`, `InboxView`, `SideTerminalsView`, `AttentionCenter`.
- `Tests/BosunCoreTests` and `Tests/BosunTests`: Swift Testing (`@Suite`, `@Test`), fixtures trimmed from real agent-deck, tmux and GitHub output. `DeckModelTests` run the model on `FakeAgentDeck` through `DeckFixture`, which records every command the model issues. `AgentDeckIntegrationTests` run the real agent-deck and tmux in a sandbox (a `HOME` under `/tmp`, a private tmux server through `TMUX_TMPDIR`), only with `BOSUN_INTEGRATION` set. The terminal has no tests; it needs a GUI session.

## Build and run

```sh
make vendor   # libghostty (141 MB) into gitignored Vendor/, once
swift build && swift test
make integration   # the real agent-deck and tmux in a sandbox; needs both installed
make run      # build, bundle and open: build/Bosun.app on main in the main checkout, build/Bosun-test.app anywhere else
make stop     # quit the copy of this checkout and branch, and delete a test copy's bundle; `make stop-all` quits every Bosun
```

CI (`.github/workflows/ci.yml`) runs build and test on `macos-26` for PRs and main.

## Smoke tests

Two Bosuns. The main Bosun is `build/Bosun.app` of the main checkout on `main`; it runs all day and is restarted only when asked. Anywhere else, another branch or a worktree, a worktree on `main` included, `make run` builds and launches `build/Bosun-test.app`, a second instance beside the main one for trying the change. To macOS it is another app, `com.bosun.Bosun-test` named "Bosun Test", with its own notifications (it asks permission once) and its own `UserDefaults`; a notification click or an `open -b` for one copy can never launch the other. Start and restart that one freely, without asking. Never put the main Bosun on a branch's build.

The test copy must not outlive the check it was started for. Two Bosuns on one agent-deck both notify and both attach, so a test copy left behind doubles every notification the user gets, for hours, until they notice.

- `make stop`, in the checkout that ran `make run`, is the last step of every smoke test. Do it before the turn ends in which `make run` was used, whether the test passed, failed, or was cut short. Not later, not when the PR is done.
- Before ending such a turn, check: `pgrep -fl Bosun-test.app` must print nothing. A hit means a stop is still owed.
- A `Bosun-test.app` running when work begins was leaked by an earlier session. Stop it first, with `make stop` in its checkout or `pkill -f Bosun-test.app`, and tell the user.

Everything else a smoke test touches is the user's: agent-deck's sessions are their work, and the main Bosun shows every pane of them. For a check that needs a pane, make your own tmux session (`tmux new-session -d -s smoke-<what>`; Bosun's pane poll sees it, agent-deck does not list it, so no row changes) and `kill-session` it after. In a session you did not make, remove only the windows and panes you added, put back a title you set with `select-pane -T`, and kill nothing else. A worktree or checkout you added goes with `git worktree remove` before the turn ends.

Driving the test copy from an agent. Agents run in agent-deck's tmux, which the main Bosun started, so macOS checks the main Bosun's Accessibility and Screen Recording grants when an agent runs `osascript` or `screencapture`; the test copy never needs a grant of its own. `make bundle` signs ad hoc, so a grant matches one build of the main Bosun only. After it is rebuilt, System Settings still shows Bosun on, yet `osascript` fails with `-25211`, captures fail, and tccd logs `Failed to match existing code requirement for subject com.bosun.Bosun`; switching it off and on keeps the old build. Then run `tccutil reset Accessibility com.bosun.Bosun && tccutil reset ScreenCapture com.bosun.Bosun`, trigger both prompts, and ask the user to switch Bosun on in both lists. If captures still fail once Accessibility works, ask the user to check Screen & System Audio Recording before asking to restart the main Bosun.

```sh
swift - <<'EOF'
import ApplicationServices
import CoreGraphics
print("accessibility:", AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary), "screen-capture:", CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess())
EOF
```

Both copies run as process `Bosun`, and System Events resolves a process by name, so `osascript` cannot address the test copy while both run. Drive it through the Accessibility API by PID instead: `AXUIElementCreateApplication(pid)` to read and press elements, and `CGEvent.postToPid(pid)` for keys, after `NSRunningApplication(processIdentifier:)?.activate()` and a check that `NSWorkspace.shared.frontmostApplication` is the test copy; keys posted to an app in the background are dropped.

## Things not obvious from the code

- tmux's first window of a session runs the agent; Bosun attaches through its own grouped "view" sessions (`ViewSession`) so switching windows does not move other clients.
- Session status comes from agent-deck's event bus (`events follow`) with a periodic `list` reconcile; omp's pane titles are polled for turn ends and questions.
- `open` hands Bosun the launching shell's environment, and libghostty copies the process environment into every shell Bosun opens. `LaunchEnvironment.sanitize()` runs first thing at launch and keeps only a terminal's variables, so a Bosun started from tmux or an agent's pane does not pass `TMUX`, `CI`, `NO_COLOR` or `AGENTDECK_KILL_SCOPE` to the user's shells.
- Comments say why a line exists, in full sentences; no "what" comments, no caller lists.
- Never amend or force-push.
