import Foundation
import Testing
@testable import Bosun
@testable import BosunCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func session(_ id: String, status: SessionStatus = .idle, substate: String? = nil, active: Date? = nil) -> DeckSession {
    DeckSession(
        id: id, title: id, path: "/p", group: "g", tool: "codex", status: status,
        substate: substate, tmuxSession: "agentdeck_\(id)", worktreePath: nil, archived: false, lastActivityAt: active
    )
}

private func pane(_ paneID: String, in sessionID: String, window: String = "@1", _ title: String) -> AgentPane {
    AgentPane(tmuxSession: "agentdeck_\(sessionID)", windowID: window, paneID: paneID, panePID: 1, title: OmpTitle(title)!)
}

private let sessionIDs = ["agentdeck_a": "a", "agentdeck_b": "b"]

/// What agent-deck's status changes mean for unread.
@Suite struct AttentionStatusTests {
    @Test func turnEndingIsUnreadUntilTheNextTurn() {
        var state = AttentionState()
        let events = state.statusChanged(sessionID: "a", from: .running, to: .waiting, at: t0)
        #expect(events.map(\.unread.kind) == [.finished])
        #expect(events.map(\.notify) == [true])
        _ = state.statusChanged(sessionID: "a", from: .waiting, to: .running, at: t0)
        #expect(state.unreadCount == 0)
    }

    @Test func failingIsUnreadOnce() {
        var state = AttentionState()
        #expect(state.statusChanged(sessionID: "a", from: .running, to: .error, at: t0).map(\.unread.kind) == [.failed])
        #expect(state.statusChanged(sessionID: "a", from: .error, to: .error, at: t0).isEmpty)
    }

    /// The TUI acknowledging means you saw it there; a shell's prompt
    /// returning, or a turn agent-deck already counts as seen, is not news.
    @Test func acknowledgedOrIdleTurnsAreNotUnread() {
        var state = AttentionState()
        _ = state.statusChanged(sessionID: "a", from: .running, to: .waiting, at: t0)
        _ = state.statusChanged(sessionID: "a", from: .waiting, to: .idle, at: t0)
        #expect(state.statusChanged(sessionID: "b", from: .running, to: .idle, at: t0).isEmpty)
        #expect(state.unreadCount == 0)
    }

    /// omp's panes say when its turns end; agent-deck only guesses for it,
    /// though an error it reports still counts.
    @Test func sessionWithOmpTakesTurnsFromItsPanes() {
        var state = AttentionState()
        _ = state.panesPolled([pane("%1", in: "a", "π ⠋ work")], sessionIDs: sessionIDs, at: t0)
        #expect(state.statusChanged(sessionID: "a", from: .running, to: .waiting, at: t0).isEmpty)
        #expect(state.statusChanged(sessionID: "a", from: .running, to: .error, at: t0).map(\.unread.kind) == [.failed])
    }
}

/// The menu bar's Needs attention section: what wants you, most urgent first.
@Suite struct AttentionOrderTests {
    @Test func questionsThenFailuresThenTurnsNewestFirst() {
        var state = AttentionState()
        _ = state.statusChanged(sessionID: "old", from: .running, to: .waiting, at: t0)
        _ = state.statusChanged(sessionID: "new", from: .running, to: .waiting, at: t0.addingTimeInterval(60))
        _ = state.statusChanged(sessionID: "failed", from: .running, to: .error, at: t0)
        let sessions = [
            session("quiet"), session("old"), session("failed"), session("new"),
            // A question waits whether or not you saw it ask.
            session("asks", status: .waiting, substate: "interactive-menu"),
        ]
        #expect(state.wantingYou(sessions).map(\.id) == ["asks", "failed", "new", "old"])
    }
}

/// What omp's pane titles mean for unread.
@Suite struct AttentionPaneTests {
    @Test func paneBackAtItsPromptIsUnreadWithItsTask() throws {
        var state = AttentionState()
        _ = state.panesPolled([pane("%1", in: "a", window: "@7", "π ⠋ ⚓ Fix it")], sessionIDs: sessionIDs, at: t0)
        let event = try #require(state.panesPolled([pane("%1", in: "a", window: "@7", "π > ⚓ Fix it")], sessionIDs: sessionIDs, at: t0).first)
        #expect(event.key == AttentionKey(sessionID: "a", paneID: "%1"))
        #expect(event.unread == Unread(kind: .finished, since: t0, label: "⚓ Fix it", windowID: "@7"))
        #expect(event.notify)
    }

    /// Answering clears a question; leaving it unanswered leaves a turn's end.
    @Test(arguments: [("π ⠋ x", 0), ("π > x", 1)])
    func questionClearsOnAnAnswer(next: String, unreadLeft: Int) {
        var state = AttentionState()
        _ = state.panesPolled([pane("%1", in: "a", "π ⠋ x")], sessionIDs: sessionIDs, at: t0)
        #expect(state.panesPolled([pane("%1", in: "a", "π ! x")], sessionIDs: sessionIDs, at: t0).map(\.notify) == [true])
        _ = state.panesPolled([pane("%1", in: "a", next)], sessionIDs: sessionIDs, at: t0)
        #expect(state.unreadCount == unreadLeft)
    }

    /// A new turn means the last one is old news, as agent-deck's `running`
    /// does; a relaunch that finds the pane working again agrees.
    @Test func newTurnClearsAFinishedPane() {
        var state = AttentionState()
        _ = state.panesPolled([pane("%1", in: "a", "π ⠋ x")], sessionIDs: sessionIDs, at: t0)
        _ = state.panesPolled([pane("%1", in: "a", "π > x")], sessionIDs: sessionIDs, at: t0)
        var relaunched = AttentionState(snapshot: state.snapshot)
        _ = state.panesPolled([pane("%1", in: "a", "π ⠋ x")], sessionIDs: sessionIDs, at: t0)
        #expect(state.unreadCount == 0)
        _ = relaunched.panesPolled([pane("%1", in: "a", "π ⠋ x")], sessionIDs: sessionIDs, at: t0)
        #expect(relaunched.unreadCount == 0)
    }

    /// At launch every pane is new: one already asking is unread without a
    /// notification, one at its prompt is nothing.
    @Test func firstSightIsQuiet() {
        var state = AttentionState()
        let events = state.panesPolled(
            [pane("%1", in: "a", "π ! x"), pane("%2", in: "b", "π > y")], sessionIDs: sessionIDs, at: t0
        )
        #expect(events.map(\.key.paneID) == ["%1"])
        #expect(events.map(\.notify) == [false])
    }

    /// Two omp instances split in one window are two things to read, and a
    /// pane that is gone takes its unread with it.
    @Test func panesAreCountedOneByOne() {
        var state = AttentionState()
        _ = state.panesPolled([pane("%1", in: "a", "π ⠋ x"), pane("%2", in: "a", "π ⠋ y")], sessionIDs: sessionIDs, at: t0)
        _ = state.panesPolled([pane("%1", in: "a", "π > x"), pane("%2", in: "a", "π > y")], sessionIDs: sessionIDs, at: t0)
        #expect(state.unreadCount == 2)
        _ = state.panesPolled([pane("%2", in: "a", "π > y")], sessionIDs: sessionIDs, at: t0)
        #expect(state.unreadCount == 1)
    }

    @Test func panesOutsideAgentDeckAreIgnored() {
        var state = AttentionState()
        _ = state.panesPolled([pane("%1", in: "mine", "π ⠋ x")], sessionIDs: sessionIDs, at: t0)
        #expect(state.panesPolled([pane("%1", in: "mine", "π > x")], sessionIDs: sessionIDs, at: t0).isEmpty)
    }
}

/// You looking, and the row's view of it.
@Suite struct AttentionSeenTests {
    static func twoWindows() -> AttentionState {
        var state = AttentionState()
        _ = state.statusChanged(sessionID: "a", from: .running, to: .error, at: t0)
        _ = state.panesPolled([pane("%1", in: "a", window: "@1", "π ⠋ x"), pane("%2", in: "a", window: "@2", "π ⠋ y")], sessionIDs: sessionIDs, at: t0)
        _ = state.panesPolled([pane("%1", in: "a", window: "@1", "π > x"), pane("%2", in: "a", window: "@2", "π > y")], sessionIDs: sessionIDs, at: t0)
        return state
    }

    /// A window on screen shows all of its panes, not the other windows'.
    @Test func seeingAWindowClearsItsPanesAndTheSession() {
        var state = Self.twoWindows()
        state.seen(sessionID: "a", windowID: "@1")
        #expect(!state.isUnread(AttentionKey(sessionID: "a", paneID: nil)))
        #expect(!state.isUnread(AttentionKey(sessionID: "a", paneID: "%1")))
        #expect(state.isUnread(AttentionKey(sessionID: "a", paneID: "%2")))
    }

    /// The same rule decides whether a notification would be about what is
    /// on screen: the session's own, and a pane's in the shown window or
    /// while the window is unknown.
    @Test func onScreenIsOneRule() {
        let state = Self.twoWindows()
        #expect(state.isOnScreen(AttentionKey(sessionID: "a", paneID: nil), sessionID: "a", windowID: "@2"))
        #expect(state.isOnScreen(AttentionKey(sessionID: "a", paneID: "%2"), sessionID: "a", windowID: "@2"))
        #expect(state.isOnScreen(AttentionKey(sessionID: "a", paneID: "%2"), sessionID: "a", windowID: nil))
        #expect(!state.isOnScreen(AttentionKey(sessionID: "a", paneID: "%2"), sessionID: "a", windowID: "@1"))
        #expect(!state.isOnScreen(AttentionKey(sessionID: "a", paneID: nil), sessionID: "b", windowID: nil))
        #expect(!state.isOnScreen(AttentionKey(sessionID: "a", paneID: nil), sessionID: nil, windowID: nil))
    }

    @Test func seeingWithoutAWindowClearsTheWholeSession() {
        var state = Self.twoWindows()
        state.seen(sessionID: "a", windowID: nil)
        #expect(state.unreadCount == 0)
    }

    /// A question outranks a failure, which outranks a turn's end; seeing it
    /// leaves the question open.
    @Test func rowSaysTheMostUrgentThing() {
        var state = Self.twoWindows()
        #expect(state.attention(for: session("a")) == SessionAttention(unread: true, asks: false, summary: "Failed", urgency: Urgency(kind: .failed, since: t0)))
        _ = state.panesPolled([pane("%1", in: "a", window: "@1", "π ! Pick one"), pane("%2", in: "a", window: "@2", "π > y")], sessionIDs: sessionIDs, at: t0)
        state.seen(sessionID: "a", windowID: nil)
        #expect(state.attention(for: session("a")) == SessionAttention(unread: false, asks: true, summary: "Asks for input: Pick one", urgency: Urgency(kind: .asks, since: .distantPast)))
    }

    /// Mark as Unread holds through looking at the session, until another
    /// one is shown.
    @Test func markedUnreadHoldsUntilAnotherSessionIsShown() {
        var state = AttentionState()
        state.markUnread(sessionID: "a", at: t0)
        state.seen(sessionID: "a", windowID: "@1")
        #expect(state.attention(for: session("a")).unread)
        state.unpin()
        state.seen(sessionID: "a", windowID: "@1")
        #expect(!state.attention(for: session("a")).unread)
    }
}

/// Session lists: what the event stream missed, and what happened while
/// Bosun was closed.
@Suite struct AttentionListTests {
    @Test func listCatchesChangesTheStreamMissed() {
        var state = AttentionState()
        _ = state.listed([session("a", status: .running)], previous: nil, at: t0)
        let events = state.listed(
            [session("a", status: .waiting, substate: "interactive-menu")], previous: [session("a", status: .running)], at: t0
        )
        #expect(events.map(\.unread.kind) == [.finished, .asks])
        #expect(state.attention(for: session("a", substate: "interactive-menu")).asks)
    }

    /// The very first list knows nothing about before; later launches mark
    /// what went waiting or failed since Bosun last listed, without a
    /// notification.
    @Test func launchMarksQuietlyWhatHappenedWhileClosed() {
        var state = AttentionState()
        #expect(state.listed([session("a", status: .waiting, active: t0)], previous: nil, at: t0).isEmpty)
        var relaunched = AttentionState(snapshot: state.snapshot)
        let later = t0.addingTimeInterval(3600)
        let events = relaunched.listed([
            session("a", status: .waiting, active: t0.addingTimeInterval(60)),
            session("b", status: .error, active: t0.addingTimeInterval(60)),
            session("c", status: .waiting, active: t0.addingTimeInterval(-60)),
            session("d", status: .running, active: t0.addingTimeInterval(60)),
        ], previous: nil, at: later)
        #expect(events.map(\.key.sessionID) == ["a", "b"])
        #expect(events.map(\.unread.kind) == [.finished, .failed])
        #expect(events.map(\.notify) == [false, false])
    }

    @Test func goneSessionsLeaveNothingUnread() {
        var state = AttentionState()
        _ = state.statusChanged(sessionID: "a", from: .running, to: .waiting, at: t0)
        _ = state.listed([session("b")], previous: [session("a"), session("b")], at: t0)
        #expect(state.unreadCount == 0)
    }

    /// What is unread outlives a quit.
    @Test func unreadSurvivesARelaunch() {
        var state = AttentionState()
        _ = state.panesPolled([pane("%1", in: "a", window: "@3", "π ⠋ x")], sessionIDs: sessionIDs, at: t0)
        _ = state.panesPolled([pane("%1", in: "a", window: "@3", "π > x")], sessionIDs: sessionIDs, at: t0)
        let data = try? JSONEncoder().encode(state.snapshot)
        let restored = data.flatMap { try? JSONDecoder().decode(AttentionState.Snapshot.self, from: $0) }.map(AttentionState.init(snapshot:))
        #expect(restored?.isUnread(AttentionKey(sessionID: "a", paneID: "%1")) == true)
        #expect(restored?.window(for: "a") == "@3")
    }

    /// A pane that went away, or whose id tmux gave to another session's
    /// pane, while Bosun was closed leaves nothing to count.
    @Test func relaunchDropsPanesThatAreGone() {
        var state = AttentionState()
        _ = state.panesPolled([pane("%1", in: "a", "π ⠋ x"), pane("%2", in: "a", "π ⠋ y")], sessionIDs: sessionIDs, at: t0)
        _ = state.panesPolled([pane("%1", in: "a", "π > x"), pane("%2", in: "a", "π > y")], sessionIDs: sessionIDs, at: t0)
        var relaunched = AttentionState(snapshot: state.snapshot)
        _ = relaunched.panesPolled([pane("%2", in: "b", "π > z")], sessionIDs: sessionIDs, at: t0)
        #expect(relaunched.unreadCount == 0)
    }
}
