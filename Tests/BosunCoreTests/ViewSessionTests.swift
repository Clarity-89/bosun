import Foundation
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
        let dead = [ViewSession.name(paneID: UUID(), pid: 100), ViewSession.name(paneID: UUID(), pid: 100)]
        let names = dead + [
            ViewSession.name(paneID: UUID(), pid: 200),
            ViewSession.name(paneID: UUID(), pid: 300),
            "agentdeck_api_1a2b",
            "bosun-view-notapid-1",
        ]
        let orphans = ViewSession.orphans(in: names, ownPID: 300, isRunning: { $0 == 200 })
        #expect(orphans == dead)
    }

    /// agent-deck killed the session a lone view was grouped with; a view
    /// still grouped with its session, and agent-deck's own sessions, are
    /// not lone, whatever their group says.
    @Test func loneViewsAreAloneInTheirGroup() {
        let listed = "agentdeck_api\t2\nbosun-view-42-1\t2\nbosun-view-42-2\t1\nbosun-view-7-1\t\nagentdeck_old\t1\n"
        #expect(ViewSession.loneViews(in: listed) == ["bosun-view-42-2", "bosun-view-7-1"])
    }

    /// `ignore-size` and `session_group_size` need 3.2; a letter suffix or
    /// a `next-` build changes nothing.
    @Test(arguments: [
        ("tmux 3.7b", true),
        ("tmux 3.2", true),
        ("tmux next-3.5", true),
        ("tmux 3.1c", false),
        ("tmux 2.9a", false),
    ])
    func viewsNeedTmux32(output: String, supported: Bool) throws {
        let version = try #require(TmuxVersion(versionOutput: output))
        #expect((version >= ViewSession.minimumTmux) == supported)
    }

    @Test func versionOutputWithoutANumberIsNil() {
        #expect(TmuxVersion(versionOutput: "tmux: command not found") == nil)
    }
}
