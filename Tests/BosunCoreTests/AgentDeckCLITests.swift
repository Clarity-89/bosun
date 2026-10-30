import Testing
@testable import BosunCore

/// `agent-deck --version` strings as the binaries on a developer machine
/// actually print them: a dev build with git suffix and update hint, and a
/// stale Homebrew release.
@Suite struct VersionParsingTests {
    @Test func parsesDevBuildWithGitSuffix() {
        let version = AgentDeckVersion(versionOutput: "Agent Deck v1.16.34-14-gb3612c5ed31-dirty (update available: v1.16.34)\n")
        #expect(version == AgentDeckVersion(major: 1, minor: 16, patch: 34))
    }

    @Test func parsesPlainRelease() {
        #expect(AgentDeckVersion(versionOutput: "Agent Deck v0.26.4") == AgentDeckVersion(major: 0, minor: 26, patch: 4))
    }

    @Test func rejectsOutputWithoutVersion() {
        #expect(AgentDeckVersion(versionOutput: "💡 Update available") == nil)
    }

    @Test func ordersNumerically() {
        #expect(AgentDeckVersion(major: 1, minor: 16, patch: 34) > AgentDeckVersion(major: 1, minor: 16, patch: 9))
        #expect(AgentDeckVersion(major: 1, minor: 2, patch: 0) > AgentDeckVersion(major: 0, minor: 26, patch: 4))
    }
}

/// The choice among several installed binaries. PATH order is not a safe
/// tie-breaker: a login shell on this machine put a 0.26.4 Homebrew binary
/// ahead of the 1.16.34 dev build.
@Suite struct BinarySelectionTests {
    let old = AgentDeckVersion(major: 0, minor: 26, patch: 4)
    let supported = AgentDeckVersion.minimumSupported
    let newer = AgentDeckVersion(major: 1, minor: 16, patch: 34)

    @Test func newestQualifyingWinsOverPathOrder() throws {
        let chosen = try AgentDeckCLI.select(
            probed: [("/opt/homebrew/bin/agent-deck", old), ("/Users/me/.local/bin/agent-deck", newer)],
            configuredPath: nil
        )
        #expect(chosen.path == "/Users/me/.local/bin/agent-deck")
    }

    @Test func belowFloorIsNeverChosen() {
        #expect(throws: AgentDeckCLIError.notFound(rejected: ["/opt/homebrew/bin/agent-deck (v0.26.4)"])) {
            try AgentDeckCLI.select(probed: [("/opt/homebrew/bin/agent-deck", old)], configuredPath: nil)
        }
    }

    @Test func configuredPathWinsWhenItQualifies() throws {
        let chosen = try AgentDeckCLI.select(
            probed: [("/a/agent-deck", newer), ("/b/agent-deck", supported)],
            configuredPath: "/b/agent-deck"
        )
        #expect(chosen.path == "/b/agent-deck")
    }

    @Test func configuredPathBelowFloorFallsBackToNewest() throws {
        let chosen = try AgentDeckCLI.select(
            probed: [("/a/agent-deck", newer), ("/b/agent-deck", old)],
            configuredPath: "/b/agent-deck"
        )
        #expect(chosen.path == "/a/agent-deck")
    }

    @Test func unprobeableCandidateIsReportedNotChosen() {
        #expect(throws: AgentDeckCLIError.notFound(rejected: ["/x/agent-deck (no version)"])) {
            try AgentDeckCLI.select(probed: [("/x/agent-deck", nil)], configuredPath: nil)
        }
    }

    @Test func tiesKeepCandidateOrder() throws {
        let chosen = try AgentDeckCLI.select(
            probed: [("/first/agent-deck", newer), ("/second/agent-deck", newer)],
            configuredPath: nil
        )
        #expect(chosen.path == "/first/agent-deck")
    }
}

/// Children of Bosun must never inherit the tmux or agent-deck identity of
/// whatever shell launched Bosun, or `session attach` nests. The launcher's
/// environment is an input, so nothing here touches the test process's own.
@Suite struct ChildEnvironmentTests {
    @Test func onlyAllowlistedVariablesSurvive() {
        let environment = AgentDeckCLI.childEnvironment(binaryDirectory: nil, inherited: [
            "TMUX": "/private/tmp/tmux-501/default,5034,18",
            "TMUX_PANE": "%31",
            "AGENTDECK_KILL_SCOPE": "abc.def",
            "AGENTDECK_INSTANCE_ID": "some-session",
            "ANYTHING": "x",
        ])
        #expect(Set(environment.keys) == ["PATH", "HOME", "USER", "LOGNAME", "SHELL", "LANG"])
    }

    @Test func forwardsNonEmptyOverrides() {
        let environment = AgentDeckCLI.childEnvironment(binaryDirectory: nil, inherited: [
            "AGENTDECK_PROFILE": "work",
            "CLAUDE_CONFIG_DIR": "/Users/me/.claude-work",
            "XDG_CONFIG_HOME": "",
        ])
        #expect(environment["AGENTDECK_PROFILE"] == "work")
        #expect(environment["CLAUDE_CONFIG_DIR"] == "/Users/me/.claude-work")
        #expect(environment["XDG_CONFIG_HOME"] == nil, "an empty override is dropped, not forwarded")
    }

    @Test func binaryDirectoryLeadsPathAndPackageManagerPrefixesFollow() {
        let environment = AgentDeckCLI.childEnvironment(
            binaryDirectory: "/Users/me/.local/bin",
            inherited: ["PATH": "/usr/bin:/custom:/Users/me/.local/bin"],
            loginPath: nil
        )
        #expect(environment["PATH"] == "/Users/me/.local/bin:/usr/bin:/custom:/opt/homebrew/bin:/usr/local/bin:/bin:/usr/sbin:/sbin")
    }

    /// A tmux server Bosun starts hands this PATH to every pane, and
    /// agent-deck runs the tool as the pane's first process, so a tool the
    /// login shell finds must be on it.
    @Test func loginShellPathFollowsTheBinaryDirectory() {
        let environment = AgentDeckCLI.childEnvironment(
            binaryDirectory: "/Users/me/.local/bin",
            inherited: ["PATH": "/usr/bin:/bin"],
            loginPath: "/Users/me/.bun/bin:/opt/homebrew/bin:/usr/bin"
        )
        #expect(environment["PATH"] == "/Users/me/.local/bin:/Users/me/.bun/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/local/bin:/usr/sbin:/sbin")
    }

    /// Profile scripts may print before the shell echoes PATH.
    @Test func loginPathIsTheShellsLastLine() {
        #expect(AgentDeckCLI.loginPath(fromShellOutput: "Last login: Fri\n/Users/me/.bun/bin:/usr/bin\n") == "/Users/me/.bun/bin:/usr/bin")
        #expect(AgentDeckCLI.loginPath(fromShellOutput: "") == nil)
        #expect(AgentDeckCLI.loginPath(fromShellOutput: "zsh: command not found: pyenv\n") == nil)
    }

    /// A LaunchServices launch carries little more than `USER` and `HOME`.
    @Test func fallsBackWhenTheLauncherIsSparse() {
        let environment = AgentDeckCLI.childEnvironment(binaryDirectory: nil, inherited: ["USER": "me"], loginPath: nil)
        #expect(environment["LOGNAME"] == "me")
        #expect(environment["SHELL"] == "/bin/zsh")
        #expect(environment["LANG"] == "en_US.UTF-8")
        #expect(environment["PATH"] == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }
}

/// A failing `--json` command as agent-deck prints it: exit 1 with the reason
/// in the stdout JSON, not on stderr. The fixture is `notify-daemon install`
/// on Linux without systemd, the one failure reproducible without touching
/// launchd. A command that reports on stderr instead keeps that text.
@Suite struct ReportedFailureTests {
    @Test func stdoutEnvelopeIsTheReason() {
        let reason = "installing the notify daemon: systemd user session not available; run manually: agent-deck notify-daemon"
        let result = ProcessResult(command: "agent-deck notify-daemon install --json", status: 1, stdout: """
            {
              "code": "INVALID_OPERATION",
              "error": "\(reason)",
              "success": false
            }
            """, stderr: "")
        #expect(throws: AgentDeckCLIError.reported(reason)) {
            try AgentDeckCLI.checkReported(result)
        }
    }

    @Test func stderrFailureKeepsItsText() {
        let result = ProcessResult(command: "agent-deck events stats --json", status: 1, stdout: "", stderr: "Error: encode stats: broken pipe\n")
        let error = #expect(throws: SubprocessError.self) {
            try AgentDeckCLI.checkReported(result)
        }
        #expect(error?.localizedDescription == "Error: encode stats: broken pipe")
    }

    /// Some refusals ignore `--json` and print a plain line on stdout, as
    /// `add` does for a directory that does not exist.
    @Test func plainStdoutErrorIsTheReason() {
        let result = ProcessResult(
            command: "agent-deck add --json -t bosun-11-gone -g tmp /tmp/bosun-11-does-not-exist",
            status: 1, stdout: "Error: path does not exist: /tmp/bosun-11-does-not-exist\n", stderr: ""
        )
        #expect(throws: AgentDeckCLIError.reported("path does not exist: /tmp/bosun-11-does-not-exist")) {
            try AgentDeckCLI.checkReported(result)
        }
    }
}
