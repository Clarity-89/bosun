import BosunCore
import Foundation

/// Why something wants you.
enum AttentionKind: String, Codable, Sendable {
    /// A turn ended: the agent went back to its prompt.
    case finished
    /// A question or a tool approval waits for an answer.
    case asks
    /// The session hit an error.
    case failed

    /// The most urgent is highest.
    var rank: Int {
        switch self {
        case .asks: 2
        case .failed: 1
        case .finished: 0
        }
    }

    /// In a session row, before omp's task name.
    var label: String {
        switch self {
        case .asks: "Asks for input"
        case .failed: "Failed"
        case .finished: "Finished"
        }
    }

    var notificationBody: String {
        switch self {
        case .asks: "Asks for input"
        case .failed: "Hit an error"
        case .finished: "Finished its turn"
        }
    }
}

/// What wants you: a whole session, as agent-deck reports it, or one omp
/// instance, a tmux pane, of which a session can hold several.
struct AttentionKey: Hashable, Codable, Sendable {
    let sessionID: String
    let paneID: String?
}

/// Something that ended, asked or failed since you last looked.
struct Unread: Codable, Equatable, Sendable {
    var kind: AttentionKind
    var since: Date
    /// omp's task name for its pane.
    var label: String?
    /// The window that holds the pane, to show it.
    var windowID: String?
    /// Mark as Unread: looking does not clear it until another session is
    /// shown.
    var pinned = false
}

/// Something becoming unread; `notify` is false for what Bosun only works
/// out later, at launch or on first sight of a pane.
struct AttentionEvent: Equatable, Sendable {
    let key: AttentionKey
    let unread: Unread
    let notify: Bool
}

/// A session row's share of it.
struct SessionAttention: Equatable, Sendable {
    /// Something here ended, asked or failed since you last looked.
    var unread = false
    /// A question or approval waits, as of the last poll or list.
    var asks = false
    /// What to say about it: the most urgent thing and, from omp, its task.
    var summary: String?
    /// The most urgent thing, to order sessions by; nil while nothing wants you.
    var urgency: Urgency?
}

/// How much a session wants you: an open question over a failure over a
/// finished turn, the latest first among equals. A question Bosun knows only
/// from a pane or agent-deck's substate has no time, and goes last among
/// questions.
struct Urgency: Comparable, Sendable {
    let kind: AttentionKind
    let since: Date

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.kind.rank, lhs.since) < (rhs.kind.rank, rhs.since)
    }
}

/// Bosun's own idea of what needs you. agent-deck's status changes and omp's
/// pane titles say that something ended, asked or failed; only Bosun knows
/// that you looked, so unread and seen live here. agent-deck's `waiting`
/// means only that an agent is at its prompt: it stays `waiting` until its
/// TUI acknowledges, which Bosun cannot do.
struct AttentionState: Equatable, Sendable {
    private(set) var unread: [AttentionKey: Unread] = [:]
    /// When Bosun last had the session list, so a launch can tell what
    /// happened while it was closed; nil until the first list ever.
    private(set) var observedUntil: Date?
    /// omp panes from the last poll, by pane id.
    private var panes: [String: PolledPane] = [:]

    /// A polled omp pane and the agent-deck session it is in.
    private struct PolledPane: Equatable, Sendable {
        let sessionID: String
        let pane: AgentPane
    }

    var unreadCount: Int { unread.count }

    func hasUnread(sessionID: String) -> Bool {
        unread.keys.contains { $0.sessionID == sessionID }
    }

    func isUnread(_ key: AttentionKey) -> Bool { unread[key] != nil }

    // MARK: agent-deck

    /// A status change agent-deck reports. A turn ending (running to waiting)
    /// or a failure makes the session unread; the next turn, a stop, or the
    /// TUI acknowledging (waiting to idle) clears it. A session with omp in
    /// its panes takes turns from the panes instead.
    mutating func statusChanged(sessionID: String, from: SessionStatus?, to: SessionStatus, at now: Date) -> [AttentionEvent] {
        let key = AttentionKey(sessionID: sessionID, paneID: nil)
        switch to {
        case .error where from != .error:
            return setUnread(key, Unread(kind: .failed, since: now), notify: true)
        case .waiting where from == .running && !hasOmp(sessionID):
            return setUnread(key, Unread(kind: .finished, since: now), notify: true)
        case .running, .stopped:
            unread[key] = nil
        case .idle where from == .waiting:
            unread[key] = nil
        default:
            break
        }
        return []
    }

    /// A new session list. It carries what the event stream may have missed:
    /// status changes since the last list, a Claude or Codex question menu
    /// opening, sessions gone. The first list after a launch (`previous` nil)
    /// marks, quietly, what turned waiting or failed while Bosun was closed;
    /// the very first one marks nothing.
    mutating func listed(_ sessions: [DeckSession], previous: [DeckSession]?, at now: Date) -> [AttentionEvent] {
        let known = Set(sessions.map(\.id))
        unread = unread.filter { known.contains($0.key.sessionID) }
        var events: [AttentionEvent] = []
        let before = Dictionary((previous ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for session in sessions {
            let key = AttentionKey(sessionID: session.id, paneID: nil)
            if let old = before[session.id] {
                if old.status != session.status {
                    events += statusChanged(sessionID: session.id, from: old.status, to: session.status, at: now)
                }
                if session.asksInAgentDeck, !old.asksInAgentDeck {
                    events += setUnread(key, Unread(kind: .asks, since: now), notify: true)
                }
            } else if previous == nil, let observedUntil, let active = session.lastActivityAt, active > observedUntil,
                      [.waiting, .error].contains(session.status) {
                events += setUnread(key, Unread(kind: session.status == .error ? .failed : .finished, since: now), notify: false)
            }
        }
        observedUntil = now
        return events
    }

    // MARK: omp

    /// One poll of omp's pane titles. A pane whose omp went from working to
    /// its prompt is unread, one that asks is unread too; a new turn, an
    /// answer included, clears it. A pane seen for the first time already
    /// asking is unread without a notification. Panes that are gone take
    /// their unread with them.
    mutating func panesPolled(_ polled: [AgentPane], sessionIDs: [String: String], at now: Date) -> [AttentionEvent] {
        var next: [String: PolledPane] = [:]
        var events: [AttentionEvent] = []
        for pane in polled {
            guard let sessionID = sessionIDs[pane.tmuxSession] else { continue }
            next[pane.paneID] = PolledPane(sessionID: sessionID, pane: pane)
            let key = AttentionKey(sessionID: sessionID, paneID: pane.paneID)
            let found = Unread(kind: .finished, since: now, label: pane.title.label, windowID: pane.windowID)
            switch (panes[pane.paneID]?.pane.title.state, pane.title.state) {
            case (.working?, .atPrompt):
                events += setUnread(key, found, notify: true)
            case (let old, .asks) where old != .asks:
                events += setUnread(key, Unread(kind: .asks, since: now, label: found.label, windowID: found.windowID), notify: old != nil)
            case (_, .working):
                unread[key] = nil
            case (.asks?, .atPrompt):
                // The question went without an answer, Esc say; what is left
                // to see is a turn's end.
                unread[key]?.kind = .finished
            default:
                break
            }
        }
        // Saved ones too: a relaunch starts without the last poll's panes,
        // and tmux reuses pane ids.
        unread = unread.filter { key, _ in
            key.paneID.map { next[$0]?.sessionID == key.sessionID } ?? true
        }
        panes = next
        return events
    }

    // MARK: you

    /// You looked at the session, in `windowID` when Bosun knows it: its own
    /// unread and its panes in that window are no longer unread, Mark as
    /// Unread aside.
    mutating func seen(sessionID: String, windowID: String?) {
        unread = unread.filter { key, item in
            item.pinned || !isOnScreen(key, sessionID: sessionID, windowID: windowID)
        }
    }

    /// Whether the pane, showing `sessionID` in `windowID` (nil while Bosun
    /// does not know which window it shows), has what `key` wants you for
    /// in front of you.
    func isOnScreen(_ key: AttentionKey, sessionID: String?, windowID: String?) -> Bool {
        guard key.sessionID == sessionID, let item = unread[key] else { return false }
        return item.windowID == nil || windowID == nil || item.windowID == windowID
    }

    mutating func markUnread(sessionID: String, at now: Date) {
        unread[AttentionKey(sessionID: sessionID, paneID: nil)] = Unread(kind: .finished, since: now, pinned: true)
    }

    /// Another session is shown: what you marked unread can be seen again.
    mutating func unpin() {
        for key in unread.keys { unread[key]?.pinned = false }
    }

    /// The row's view of a session: any unread, a question open in any of its
    /// panes or in agent-deck's substate, and the most urgent of them to say.
    func attention(for session: DeckSession) -> SessionAttention {
        let mine = unread.filter { $0.key.sessionID == session.id }.map(\.value)
        let asking = panes.values.filter { $0.sessionID == session.id && $0.pane.title.state == .asks }.map(\.pane)
        let asks = !asking.isEmpty || session.asksInAgentDeck
        let top = mine.max { ($0.kind.rank, $0.since) < ($1.kind.rank, $1.since) }
        var summary: String?
        var urgency: Urgency?
        if asks {
            summary = Self.say(.asks, asking.first?.title.label ?? mine.first { $0.kind == .asks }?.label)
            urgency = Urgency(kind: .asks, since: top?.since ?? .distantPast)
        } else if let top {
            summary = Self.say(top.kind, top.label)
            urgency = Urgency(kind: top.kind, since: top.since)
        }
        return SessionAttention(unread: !mine.isEmpty, asks: asks, summary: summary, urgency: urgency)
    }

    /// The sessions that want you, most urgent first.
    func wantingYou(_ sessions: [DeckSession]) -> [DeckSession] {
        sessions.compactMap { session in attention(for: session).urgency.map { (session, $0) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// Where to show what is unread for a session: the window of its most
    /// recent omp pane that wants you, nil for the session itself.
    func window(for sessionID: String) -> String? {
        unread.filter { $0.key.sessionID == sessionID }.max { $0.value.since < $1.value.since }?.value.windowID
    }

    private func hasOmp(_ sessionID: String) -> Bool {
        panes.values.contains { $0.sessionID == sessionID }
    }

    private mutating func setUnread(_ key: AttentionKey, _ item: Unread, notify: Bool) -> [AttentionEvent] {
        unread[key] = item
        return [AttentionEvent(key: key, unread: item, notify: notify)]
    }

    private static func say(_ kind: AttentionKind, _ label: String?) -> String {
        label.map { "\(kind.label): \($0)" } ?? kind.label
    }
}

extension DeckSession {
    /// A Claude or Codex question or permission menu, the only harnesses for
    /// which agent-deck can tell one from a finished turn.
    var asksInAgentDeck: Bool { substate == "interactive-menu" }
}

// MARK: Saved state

extension AttentionState {
    /// What outlives a quit: what is unread, and when Bosun last looked.
    struct Snapshot: Codable {
        struct Entry: Codable {
            let key: AttentionKey
            let unread: Unread
        }
        let unread: [Entry]
        let observedUntil: Date?
    }

    var snapshot: Snapshot {
        Snapshot(unread: unread.map { Snapshot.Entry(key: $0.key, unread: $0.value) }, observedUntil: observedUntil)
    }

    init(snapshot: Snapshot) {
        unread = Dictionary(snapshot.unread.map { ($0.key, $0.unread) }, uniquingKeysWith: { _, last in last })
        observedUntil = snapshot.observedUntil
    }
}
