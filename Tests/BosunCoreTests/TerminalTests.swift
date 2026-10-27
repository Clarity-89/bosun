import Testing
@testable import BosunCore

/// The command libghostty runs as `sh -c "exec <command>"`; agent-deck's
/// session ids and the binary path must survive `sh` quoting.
@Suite struct AttachCommandTests {
    /// No `exec` of its own: libghostty adds one, and a second yields
    /// "exec: exec: not found".
    @Test func quotesPathAndSessionForSh() {
        let command = Terminal.attachCommand(executablePath: "/Users/me/.local/bin/agent-deck", sessionID: "8fdb4c7d-1792761516")
        #expect(command == "'/Users/me/.local/bin/agent-deck' session attach '8fdb4c7d-1792761516'")
    }

    @Test func escapesSingleQuotesInsideQuotedWords() {
        let command = Terminal.attachCommand(executablePath: "/Users/o'brien/agent-deck", sessionID: "id")
        #expect(command.hasPrefix("'/Users/o'\\''brien/agent-deck' "))
    }

    @Test func ghosttyPopOutUsesExecOnceAndQuitsWithItsWindow() {
        let arguments = Terminal.attachArguments(executablePath: "/x/agent-deck", sessionID: "y")
        #expect(arguments.contains("--quit-after-last-window-closed=true"))
        #expect(arguments.last?.hasPrefix("exec '/x/agent-deck' session attach") == true)
    }
}
