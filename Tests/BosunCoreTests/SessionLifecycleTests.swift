import Testing
@testable import BosunCore

/// Replies as agent-deck v1.16.34 prints them for a throwaway shell session.
@Suite struct SessionLifecycleReplyTests {
    @Test func restartThatRanPasses() throws {
        let result = ProcessResult(command: "agent-deck session restart --json", status: 0, stdout: """
            {
              "id": "92d81845-1793166953",
              "success": true,
              "title": "bosun-lc-probe"
            }
            """, stderr: "")
        try AgentDeckCLI.checkRestarted(result)
    }

    /// agent-deck exits 0 for a skipped restart; only `skipped` says nothing ran.
    @Test func skippedRestartFailsWithItsReason() {
        let reason = "session is starting and was started 1s ago (within 1m0s freshness window); use --force to restart anyway"
        let result = ProcessResult(command: "agent-deck session restart --json", status: 0, stdout: """
            {
              "id": "92d81845-1793166953",
              "reason": "\(reason)",
              "skipped": true,
              "success": true,
              "title": "bosun-lc-probe"
            }
            """, stderr: "")
        #expect(throws: AgentDeckCLIError.reported("Restart skipped: \(reason)")) {
            try AgentDeckCLI.checkRestarted(result)
        }
    }
}
