import Testing
@testable import BosunCore

/// `tmux list-windows -a` lines in `WindowListing.format`: session, index,
/// id, name, command, and whether the window is the session's current one.
@Suite struct TmuxWindowParsingTests {
    static let output = """
    agentdeck_a_1\t0\t@3\tclaude\tnode\t0
    agentdeck_a_1\t1\t@7\tzsh\tzsh\t1
    agentdeck_a_1\t2\t@9\tlogs\ttail\t0
    agentdeck_b_2\t0\t@4\tbash\tbash\t1
    bosun-view-42-abcd\t0\t@3\tclaude\tnode\t1
    bosun-view-42-abcd\t1\t@7\tzsh\tzsh\t0
    bosun-view-42-abcd\t2\t@9\tlogs\ttail\t0
    """

    @Test func groupsWindowsBySessionInTmuxOrder() {
        let windows = WindowListing(listOutput: Self.output).windows
        #expect(windows["agentdeck_a_1"]?.map(\.index) == [0, 1, 2])
        #expect(windows["agentdeck_a_1"]?.map(\.windowID) == ["@3", "@7", "@9"])
        #expect(windows["agentdeck_a_1"]?[2].command == "tail")
        #expect(windows["agentdeck_b_2"]?.count == 1)
    }

    /// A view grouped with a session shares its windows but is on one of
    /// its own choosing.
    @Test func eachSessionHasItsOwnCurrentWindow() {
        let current = WindowListing(listOutput: Self.output).currentWindows
        #expect(current == ["agentdeck_a_1": "@7", "agentdeck_b_2": "@4", "bosun-view-42-abcd": "@3"])
    }

    @Test func emptyWindowNameIsKeptAsEmpty() {
        let listing = WindowListing(listOutput: "s\t1\t@2\t\tbash\t1\n")
        #expect(listing.windows["s"]?.first?.name == "")
    }

    @Test func malformedLinesAreSkippedNotFatal() {
        let output = "garbage\ns\tnot-a-number\t@1\tx\ty\t1\ns\t0\t@1\tx\ty\ns\t0\t@1\tx\ty\t1\n"
        let listing = WindowListing(listOutput: output)
        #expect(listing.windows["s"]?.count == 1)
        #expect(listing.currentWindows == ["s": "@1"])
    }

    @Test func emptyOutputIsEmptyListing() {
        #expect(WindowListing(listOutput: "") == WindowListing())
    }
}
