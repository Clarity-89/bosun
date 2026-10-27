import Foundation
import Testing
@testable import BosunCore

/// `tmux list-windows -a -F '#{session_name}\t#{window_index}\t#{window_id}\t#{window_name}\t#{pane_current_command}'`
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

/// The command libghostty runs as `sh -c "exec <command>"`; agent-deck's
/// session ids and the binary path must survive `sh` quoting.
@Suite struct AttachCommandTests {
    @Test func quotesPathAndSessionForSh() {
        let command = Terminal.attachCommand(executablePath: "/Users/me/.local/bin/agent-deck", sessionID: "8fdb4c7d-1792761516")
        #expect(command == "'/Users/me/.local/bin/agent-deck' session attach '8fdb4c7d-1792761516'")
    }

    @Test func escapesSingleQuotesInsideQuotedWords() {
        let command = Terminal.attachCommand(executablePath: "/Users/o'brien/agent-deck", sessionID: "id")
        #expect(command.hasPrefix("'/Users/o'\\''brien/agent-deck' "))
    }

    @Test func embeddedCommandDoesNotPrefixExecItself() {
        // libghostty adds `exec`; a second one yields "exec: exec: not found".
        #expect(!Terminal.attachCommand(executablePath: "/x", sessionID: "y").hasPrefix("exec"))
    }

    @Test func ghosttyPopOutUsesExecOnceAndQuitsWithItsWindow() {
        let arguments = Terminal.attachArguments(executablePath: "/x/agent-deck", sessionID: "y")
        #expect(arguments.contains("--quit-after-last-window-closed=true"))
        #expect(arguments.last?.hasPrefix("exec '/x/agent-deck' session attach") == true)
    }
}

/// Children of Bosun must never inherit the tmux or agent-deck identity of
/// whatever shell launched Bosun, or `session attach` nests.
@Suite(.serialized) struct ChildEnvironmentTests {
    @Test func scrubsTmuxAndAgentDeckVariables() {
        setenv("TMUX", "/private/tmp/tmux-501/default,5034,18", 1)
        setenv("TMUX_PANE", "%31", 1)
        setenv("AGENTDECK_KILL_SCOPE", "abc.def", 1)
        setenv("AGENTDECK_INSTANCE_ID", "some-session", 1)
        defer {
            for key in ["TMUX", "TMUX_PANE", "AGENTDECK_KILL_SCOPE", "AGENTDECK_INSTANCE_ID"] { unsetenv(key) }
        }
        let environment = AgentDeckCLI.childEnvironment(binaryDirectory: nil)
        #expect(environment["TMUX"] == nil)
        #expect(environment["TMUX_PANE"] == nil)
        #expect(environment["AGENTDECK_KILL_SCOPE"] == nil)
        #expect(environment["AGENTDECK_INSTANCE_ID"] == nil)
    }

    @Test func keepsProfileAndConfigDirOverrides() {
        setenv("AGENTDECK_PROFILE", "work", 1)
        setenv("CLAUDE_CONFIG_DIR", "/Users/me/.claude-work", 1)
        defer { unsetenv("AGENTDECK_PROFILE"); unsetenv("CLAUDE_CONFIG_DIR") }
        let environment = AgentDeckCLI.childEnvironment(binaryDirectory: nil)
        #expect(environment["AGENTDECK_PROFILE"] == "work")
        #expect(environment["CLAUDE_CONFIG_DIR"] == "/Users/me/.claude-work")
    }

    @Test func binaryDirectoryLeadsPathAndPackageManagerPrefixesFollow() {
        let path = AgentDeckCLI.childEnvironment(binaryDirectory: "/Users/me/.local/bin")["PATH"] ?? ""
        let entries = path.split(separator: ":").map(String.init)
        #expect(entries.first == "/Users/me/.local/bin")
        #expect(entries.contains("/opt/homebrew/bin"))
        #expect(entries.contains("/usr/bin"))
        #expect(Set(entries).count == entries.count, "PATH entries are deduplicated")
    }
}
