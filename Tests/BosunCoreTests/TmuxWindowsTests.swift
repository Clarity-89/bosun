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
