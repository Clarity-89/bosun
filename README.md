# Bosun

A macOS app over [agent-deck](https://github.com/asheshgoplani/agent-deck). Agents keep running in tmux; Bosun lists, watches and dispatches them.

- Sessions in groups, with live status from agent-deck's event bus, and the selected one attached in an embedded terminal (libghostty).
- Notifications when an agent finishes a turn, asks a question or errors; unread marks in the list and the menu bar.
- New, stop, restart, rename and delete sessions, with git worktrees or in agent-deck's Docker sandbox; extra shell windows and splits; two side shells in the session's directory.
- Inbox: review requests, your pull requests and issues, and mentions, through `gh`. Each session shows its branch's pull request and the issue it works on.
- Toolbar buttons that open the session's directory in GoLand, VS Code or Cursor, and that ask its agent to merge main, open a pull request, or push to it.

## Requirements

macOS 26, Xcode 26 or a Swift 6.2 or later toolchain, [tmux](https://github.com/tmux/tmux) 3.2 or later, agent-deck on your PATH, and the [GitHub CLI](https://cli.github.com) signed in for the GitHub features.

Bosun preserves `SSH_AUTH_SOCK` and `TMPDIR` for agent-deck and tmux.
At startup, it repairs missing server values and clears session-level removal markers, preserving explicit per-session overrides.
Existing shells keep their old environment; open a new pane to use the repaired values.

## Build

```sh
make run    # fetches libghostty (141 MB, once), builds, bundles and opens Bosun.app
make test
make integration   # the real agent-deck and tmux, in a sandbox HOME on a private tmux server
```

## License

MIT. `Sources/BosunTerminal/Vendored` is adapted from [Calyx](https://github.com/yuuichieguchi/Calyx), also MIT.
