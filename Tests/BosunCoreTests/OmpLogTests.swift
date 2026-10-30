@preconcurrency import Foundation
import Testing
@testable import BosunCore

/// omp's session logs: only the first user message names the session's
/// purpose.
@Suite struct OmpLogTests {
    static func lines(_ objects: [String]) -> Data { Data(objects.joined(separator: "\n").utf8) }

    @Test func readsTheIssueInTheFirstPrompt() {
        let log = Self.lines([
            #"{"type":"title","title":"⚓ BOSUN","v":3}"#,
            #"{"type":"model_change","model":"x"}"#,
            #"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"Implement https://github.com/Clarity-89/bosun/issues/10 please"}]}}"#,
            #"{"type":"message","message":{"role":"user","content":"Now https://github.com/Clarity-89/bosun/issues/16"}}"#,
        ])
        #expect(OmpLog.firstIssue(inLog: log)?.description == "Clarity-89/bosun#10")
    }

    /// A first prompt without an issue means the session has none, whatever
    /// a later message mentions; tool results are not prompts.
    @Test func laterMessagesDoNotCount() {
        let log = Self.lines([
            #"{"type":"message","message":{"role":"toolResult","content":"https://github.com/a/b/issues/1"}}"#,
            #"{"type":"message","message":{"role":"user","content":"Look around the repo"}}"#,
            #"{"type":"message","message":{"role":"user","content":"https://github.com/a/b/issues/2"}}"#,
        ])
        #expect(OmpLog.firstIssue(inLog: log) == nil)
    }

    /// The read stops at a size limit, which can cut the last line short.
    @Test func skipsALineCutShort() {
        let log = Self.lines([
            #"{"type":"custom","data":"#,
            #"{"type":"message","message":{"role":"user","content":"https://github.com/octo-org/octo-repo/issues/136268"}}"#,
        ])
        #expect(OmpLog.firstIssue(inLog: log)?.number == 136268)
    }

    @Test(arguments: [
        ("/Users/me/dev/agent-deck", "/Users/me/.omp/agent/sessions/-dev-agent-deck"),
        ("/Users/me/dev/worktrees/octo-repo/me/feature", "/Users/me/.omp/agent/sessions/-dev-worktrees-octo-repo-me-feature"),
        ("/Users/me/.omp/wt/wt-20261013", "/Users/me/.omp/agent/sessions/-.omp-wt-wt-20261013"),
    ])
    func findsOmpsFolderForASession(path: String, folder: String) {
        #expect(OmpLog.directory(forWorkingDirectory: path, home: "/Users/me") == folder)
    }
}
