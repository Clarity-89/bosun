# Feature map

Bosun is a macOS app over agent-deck. Agents keep running in tmux and the
terminal; Bosun lists, tracks and dispatches. This table maps each wanted
feature to what agent-deck already exposes and what Bosun owns itself.

Probed against agent-deck v1.16.26 (local build) on 2026-10-23. Paths are
relative to the agent-deck checkout.

| Feature | Already in agent-deck | Gap / Bosun-owned part |
|---|---|---|
| Named sessions + progress | `add --json` (`-group`, `-worktree`, `-b`, `-additional-path`), `session start/stop/restart --json`, `list --json` (status, substate, tool, path, tmux_session), bus `session.status` / `session.turn{duration_ms}`, `recall timeline` for last prompt/answer | Live list from bus, reconcile with `list` every 30-60 s, `UserNotifications` on waiting/error (leave `[notifications].desktop` off; Bosun owns notifications) |
| Swap tool on outage | `harness list --json` gives `state` ready/not_logged_in/limit_reached; `limits --json`; `session switch <id> --to-harness codex --json`, `switch-preview --json`, `--confirm-context-loss --max-bytes` (default 32000) | No provider outage monitor exists. Poll statuspage JSON (`status.anthropic.com/api/v2/status.json`, OpenAI equivalent) plus `limit_reached` and auth-hold substates, then offer the switch. Cross-harness is lossy by design: always show the preview, never auto-switch |
| My issues / PRs / review requests | Nothing for "me": gh-watcher is repo-event polling for conductors (`conductor/gh-watcher`); review_requested not handled | GraphQL with `gh auth token`; searches `assignee:@me is:issue`, `author:@me is:pr`, `review-requested:@me is:pr`; fields reviewDecision, statusCheckRollup, unresolved threads. Suggestions are one-click session actions wired to existing skills: pr-review, pr-address-feedback, babysit-ci, review-comments |
| Internal kanban | Nothing | Bosun SQLite. Cards link session ids, PR/issue URLs, projects. One-click promote to GitHub issue (`gh issue create`) so the two systems do not drift. Optional `macapp.kanban.*` frames so conductors can read the board |
| Agents / skills / prompts across tools | `skill list/attached/attach/detach/source` writes `.agent-deck/skills.toml` and symlinks into `.claude/skills`, `.agents/skills` (codex/gemini/pi), `.hermes/skills`, `.omp/skills` (`internal/session/skills_catalog.go:137-170`); MCP `[mcps.<name>]` attach writes tool-native stores; agents inventory in `internal/agents` (agent.yaml) | OpenCode skills not supported; no generic system-prompt model (`identity_injection.go` is per harness). Bosun owns a prompt-fragment library and writes managed blocks (`<!-- BEGIN x -->`) into CLAUDE.md/AGENTS.md/GEMINI.md. `skill attached` has no `--json`; read `.agent-deck/skills.toml` directly |
| One-click skill invocation | No command, but composable: `session send <id> --message-file - --json --queue`, poll `send-status` to `landed`; a `/name` message lands as a command row (`docs/macapp-core.md:59`); the queue handles busy/idle per harness | Buttons from attached skills. Claude gets `/name`; other harnesses get text ("Use the <name> skill: ..."); exact per-harness syntax unverified |
| Project context | Groups (`groups` table: default_path, max_concurrent), multi-repo sessions (`-additional-path`, root under `<data>/multi-repo-worktrees`), `config show --effective <path>` | Bosun "Project" entity: repos, group path, default harness, default skill set, notes, links. Cards, PRs, sessions and journal hang off it |
| Daily activity + knowledgebase | `profiles/<p>/logs/health/sessions-YYYYMMDD.jsonl` (status/send/restart/stop, 7-day retention), bus turn durations, `costs`, `recall.db`, turn-journal | Ingest nightly before retention prunes. Nightly summary: spawn a deck session in the notes repo, `send --queue` the day's journal, write `kb/YYYY-MM-DD.md` plus a procedures file |
| Open terminal/IDE into workspace | `session show --json` gives `path`, `tmux_session` | `session show --json` exposes `path` only, no worktree or additional paths (probed). Core change. Terminal: `open -a <term>` + `agent-deck attach <id>`, or iTerm2 `tmux -CC`. IDE: `code`/`cursor`/`zed <dir>`; multi-repo gets a generated `.code-workspace` |
| Scheduled tasks | `[interval_hooks.<name>]` run only while the TUI is up (`internal/intervalhook`); gh-watcher uses launchd `StartInterval` | Write `~/Library/LaunchAgents/com.bosun.schedule.<id>.plist` running a bundled runner CLI, so `git fetch --all --prune` across project repos runs with the GUI closed. Own label prefix, not `com.agentdeck.*` |

## Core changes

Bosun drives the installed agent-deck through its CLI and event bus; these are
the agent-deck changes it needs. Nothing else in the table needs a core change.

1. `session show --json`: add `worktree_path`, `additional_paths`, `multi_repo_root`. Blocks multi-repo open-in-IDE.
2. `skill attached/attach/detach --json`.
3. Registry coverage for `session.show`, `session.send`, `harness.list`, `skill.*` so the daemon `call` path becomes useful.
4. Done on agent-deck's `feature/status-owner` branch, not upstream yet: `events stats --json` reports `status_owner` (`tui`, `notify-daemon` or `none`), and `notify-daemon install --json` installs the notify daemon without a conductor. Bosun uses both to keep statuses live with the TUI closed (#7).
