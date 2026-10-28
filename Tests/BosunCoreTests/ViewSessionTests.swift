import Testing
@testable import BosunCore

/// Bosun's own tmux sessions, grouped with agent-deck's.
@Suite struct ViewSessionTests {
    /// libghostty runs it as `sh -c "exec <command>"`: the `;` must reach
    /// tmux as its own word, and the option needs the `=name:` target.
    @Test func attachSetsDestroyUnattachedOnceAttached() {
        let command = Terminal.viewAttachCommand(tmuxPath: "/opt/homebrew/bin/tmux", view: "bosun-view-42-1", yieldsSize: false)
        #expect(command == "'/opt/homebrew/bin/tmux' attach-session -t '=bosun-view-42-1' \\; set-option -t '=bosun-view-42-1:' destroy-unattached on")
    }

    @Test func yieldingAttachLeavesTheSizeToOthers() {
        let command = Terminal.viewAttachCommand(tmuxPath: "/t/tmux", view: "bosun-view-42-1", yieldsSize: true)
        #expect(command.hasPrefix("'/t/tmux' attach-session -f ignore-size -t '=bosun-view-42-1' \\; "))
    }

    /// The TUI's client counts; the view's own, agent-deck's control-mode
    /// pipes and clients that size nothing do not, nor anyone on another
    /// window.
    @Test(arguments: [
        ("agentdeck_api\t@3\tattached,focused,UTF-8", true),
        ("bosun-view-42-1\t@3\tattached,focused,UTF-8", false),
        ("agentdeck_api\t@3\tattached,control-mode,UTF-8", false),
        ("bosun-view-77-2\t@3\tattached,ignore-size,UTF-8", false),
        ("agentdeck_api\t@4\tattached,focused,UTF-8", false),
    ])
    func someoneElseIsAPersonOnTheSameWindow(client: String, expected: Bool) {
        #expect(ViewSession.someoneElse(on: "@3", besides: "bosun-view-42-1", clients: client + "\n") == expected)
    }

    /// A crashed Bosun's views go; a running Bosun's, its own included, and
    /// every other session stay.
    @Test func orphansAreViewsOfBosunsThatAreGone() {
        let names = [
            ViewSession.name(sequence: 1, pid: 100),
            ViewSession.name(sequence: 2, pid: 100),
            ViewSession.name(sequence: 1, pid: 200),
            ViewSession.name(sequence: 1, pid: 300),
            "agentdeck_api_1a2b",
            "bosun-view-notapid-1",
        ]
        let orphans = ViewSession.orphans(in: names, ownPID: 300, isRunning: { $0 == 200 })
        #expect(orphans == [ViewSession.name(sequence: 1, pid: 100), ViewSession.name(sequence: 2, pid: 100)])
    }
}
