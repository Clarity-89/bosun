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

    @Test func newestQualifyingWinsOverPathOrder() {
        let selection = AgentDeckCLI.select(
            candidates: ["/opt/homebrew/bin/agent-deck", "/Users/me/.local/bin/agent-deck"],
            versions: ["/opt/homebrew/bin/agent-deck": old, "/Users/me/.local/bin/agent-deck": newer],
            configuredPath: nil
        )
        #expect(selection.chosen?.path == "/Users/me/.local/bin/agent-deck")
        #expect(selection.rejected == ["/opt/homebrew/bin/agent-deck (v0.26.4)"])
    }

    @Test func belowFloorIsNeverChosen() {
        let selection = AgentDeckCLI.select(
            candidates: ["/opt/homebrew/bin/agent-deck"],
            versions: ["/opt/homebrew/bin/agent-deck": old],
            configuredPath: nil
        )
        #expect(selection.chosen == nil)
        #expect(selection.rejected.count == 1)
    }

    @Test func configuredPathWinsWhenItQualifies() {
        let selection = AgentDeckCLI.select(
            candidates: ["/a/agent-deck", "/b/agent-deck"],
            versions: ["/a/agent-deck": newer, "/b/agent-deck": supported],
            configuredPath: "/b/agent-deck"
        )
        #expect(selection.chosen?.path == "/b/agent-deck")
    }

    @Test func configuredPathBelowFloorFallsBackToNewest() {
        let selection = AgentDeckCLI.select(
            candidates: ["/a/agent-deck", "/b/agent-deck"],
            versions: ["/a/agent-deck": newer, "/b/agent-deck": old],
            configuredPath: "/b/agent-deck"
        )
        #expect(selection.chosen?.path == "/a/agent-deck")
    }

    @Test func unprobeableCandidateIsReportedNotChosen() {
        let selection = AgentDeckCLI.select(candidates: ["/x/agent-deck"], versions: [:], configuredPath: nil)
        #expect(selection.chosen == nil)
        #expect(selection.rejected == ["/x/agent-deck (no version)"])
    }

    @Test func tiesKeepCandidateOrder() {
        let selection = AgentDeckCLI.select(
            candidates: ["/first/agent-deck", "/second/agent-deck"],
            versions: ["/first/agent-deck": newer, "/second/agent-deck": newer],
            configuredPath: nil
        )
        #expect(selection.chosen?.path == "/first/agent-deck")
    }
}
