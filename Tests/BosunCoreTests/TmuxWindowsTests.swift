import Testing
@testable import BosunCore

/// `tmux list-windows -a` lines in `SessionWindow.listFormat`: session,
/// index, id, name, command.
@Suite struct TmuxWindowParsingTests {
    @Test func groupsWindowsBySessionInTmuxOrder() {
        let output = """
        agentdeck_a_1\t0\t@3\tclaude\tnode
        agentdeck_a_1\t1\t@7\tzsh\tzsh
        agentdeck_a_1\t2\t@9\tlogs\ttail
        agentdeck_b_2\t0\t@4\tbash\tbash
        """
        let windows = SessionWindow.parse(listOutput: output)
        #expect(windows["agentdeck_a_1"]?.map(\.index) == [0, 1, 2])
        #expect(windows["agentdeck_a_1"]?.map(\.windowID) == ["@3", "@7", "@9"])
        #expect(windows["agentdeck_a_1"]?[2].command == "tail")
        #expect(windows["agentdeck_b_2"]?.count == 1)
    }

    @Test func emptyWindowNameIsKeptAsEmpty() {
        let windows = SessionWindow.parse(listOutput: "s\t1\t@2\t\tbash\n")
        #expect(windows["s"]?.first?.name == "")
    }

    @Test func malformedLinesAreSkippedNotFatal() {
        let output = "garbage\ns\tnot-a-number\t@1\tx\ty\ns\t0\t@1\tx\ty\n"
        let windows = SessionWindow.parse(listOutput: output)
        #expect(windows["s"]?.count == 1)
    }

    @Test func emptyOutputIsEmptyMap() {
        #expect(SessionWindow.parse(listOutput: "").isEmpty)
    }
}

/// `tmux list-panes -F` lines in `AgentDeckCLI.paneFormat`: id, active,
/// command. The request goes to the active pane unless a shell prompt
/// waits there; nil leaves it to the top-left pane.
@Suite struct AgentPaneChoiceTests {
    @Test func theActivePaneTakesItWhileAProgramRunsThere() {
        let output = "%1\t0\tnode\n%4\t1\tnode\n"
        #expect(AgentDeckCLI.agentPane(listOutput: output) == "%4")
    }

    @Test(arguments: ["zsh", "bash", "fish", "login"])
    func aShellPromptInTheActivePaneLeavesItToTheTopLeft(shell: String) {
        let output = "%1\t0\tnode\n%4\t1\t\(shell)\n"
        #expect(AgentDeckCLI.agentPane(listOutput: output) == nil)
    }

    @Test func noActivePaneLeavesItToTheTopLeft() {
        #expect(AgentDeckCLI.agentPane(listOutput: "%1\t0\tnode\n") == nil)
        #expect(AgentDeckCLI.agentPane(listOutput: "") == nil)
    }
}
