import BosunCore
import Foundation
import Observation
import os

/// What needs you, and what follows from it: the notifications, what counts
/// as seen, and what outlives a quit. AttentionState holds the rules; this
/// feeds it what happened and acts on the difference.
@MainActor
@Observable
final class AttentionCenter {
    /// Saved whenever what is unread, or when Bosun last looked, changes.
    private(set) var state = AttentionCenter.saved() {
        didSet {
            guard oldValue.unread != state.unread || oldValue.observedUntil != state.observedUntil,
                  let data = try? JSONEncoder().encode(state.snapshot)
            else { return }
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    /// Notifications waiting out their 3 s, by what they are about.
    @ObservationIgnored private var pending: [AttentionKey: Task<Void, Never>] = [:]
    @ObservationIgnored private var seenTask: Task<Void, Never>?
    /// Bosun is active with the main window on screen.
    @ObservationIgnored private var windowInFront = false
    /// The Inbox has the pane's place.
    @ObservationIgnored private var paneCovered = false
    /// What the pane shows is in front of you.
    private var inFront: Bool { windowInFront && !paneCovered }
    /// The session the pane shows, and its window when Bosun knows it.
    @ObservationIgnored private var shownSessionID: String?
    @ObservationIgnored private var shownWindowID: String?
    /// A session whose agent just finished a turn, as it happened, not
    /// worked out later at launch.
    @ObservationIgnored var onTurnEnd: ((DeckSession) -> Void)?

    /// Each session's own unread and each of its omp panes'.
    var count: Int { state.unreadCount }

    subscript(session: DeckSession) -> SessionAttention {
        state.attention(for: session)
    }

    /// Of `sessions`, those that want you, most urgent first.
    func wantingYou(_ sessions: [DeckSession]) -> [DeckSession] {
        state.wantingYou(sessions)
    }

    /// Where to show a session's unread: the window of its most recent omp
    /// pane that wants you, nil for the session itself.
    func window(for sessionID: String) -> String? {
        state.window(for: sessionID)
    }

    func stop() {
        seenTask?.cancel()
        pending.values.forEach { $0.cancel() }
    }

    // MARK: What happened

    func statusChanged(_ session: DeckSession, from: SessionStatus?, to: SessionStatus) {
        apply(in: [session]) { $0.statusChanged(sessionID: session.id, from: from, to: to, at: .now) }
    }

    func listed(_ sessions: [DeckSession], previous: [DeckSession]?) {
        apply(in: sessions) { $0.listed(sessions, previous: previous, at: .now) }
    }

    /// One poll of omp's panes, matched to sessions by tmux session name.
    func panesPolled(_ panes: [AgentPane], sessions: [DeckSession]) {
        let sessionIDs = Dictionary(
            sessions.compactMap { session in session.tmuxSession.map { ($0, session.id) } },
            uniquingKeysWith: { first, _ in first }
        )
        apply(in: sessions) { $0.panesPolled(panes, sessionIDs: sessionIDs, at: .now) }
    }

    // MARK: What you do

    /// The pane shows `sessionID`, in `windowID` when Bosun knows it. It
    /// counts as seen after a second in front of you; a different session
    /// than before releases Mark as Unread.
    func shown(sessionID: String?, windowID: String?) {
        if sessionID != shownSessionID {
            apply { $0.unpin() }
        }
        shownSessionID = sessionID
        shownWindowID = windowID
        scheduleSeen()
    }

    /// Bosun became active or not, or the main window came on screen or
    /// went off it.
    func inFront(_ inFront: Bool) {
        guard inFront != windowInFront else { return }
        windowInFront = inFront
        scheduleSeen()
    }

    /// The Inbox took the pane's place, or gave it back: a covered session
    /// is neither seen nor spared its notifications.
    func paneCovered(_ covered: Bool) {
        guard covered != paneCovered else { return }
        paneCovered = covered
        scheduleSeen()
    }

    func markUnread(sessionID: String) {
        apply { $0.markUnread(sessionID: sessionID, at: .now) }
    }

    // MARK: Acting on a change

    private func apply(_ change: (inout AttentionState) -> Void) {
        apply(in: []) { change(&$0); return [] }
    }

    /// Applies a change and acts on the difference. What left unread takes
    /// its notification with it, pending or delivered; what became unread
    /// gets one, with its session, from `sessions`, named in it.
    private func apply(in sessions: [DeckSession], _ change: (inout AttentionState) -> [AttentionEvent]) {
        var next = state
        let events = change(&next)
        guard next != state else { return }
        let gone = Set(state.unread.keys).subtracting(next.unread.keys)
        state = next
        if !gone.isEmpty {
            for key in gone { pending.removeValue(forKey: key)?.cancel() }
            Notifier.shared.remove(ids: gone.map(Self.notificationID))
            logger.info("no longer unread: \(gone.map(Self.notificationID).joined(separator: " "), privacy: .public)")
        }
        for event in events where event.notify {
            if let session = sessions.first(where: { $0.id == event.key.sessionID }) {
                queue(event, about: session)
            }
        }
        if events.contains(where: { $0.key.sessionID == shownSessionID }) {
            scheduleSeen()
        }
        let ended = Set(events.filter { $0.notify && $0.unread.kind == .finished }.map(\.key.sessionID))
        for session in sessions where ended.contains(session.id) {
            onTurnEnd?(session)
        }
    }

    /// Waits out harnesses that flap back to running for a moment mid-turn:
    /// the notification goes only if it is still unread after 3 s.
    private func queue(_ event: AttentionEvent, about session: DeckSession) {
        guard AttentionSettings.notifies(event.unread.kind) else { return }
        pending.removeValue(forKey: event.key)?.cancel()
        pending[event.key] = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            pending[event.key] = nil
            post(event.key, about: session)
        }
    }

    /// Never for what is on screen in front of you.
    private func post(_ key: AttentionKey, about session: DeckSession) {
        guard let unread = state.unread[key], AttentionSettings.notifies(unread.kind) else { return }
        if inFront, state.isOnScreen(key, sessionID: shownSessionID, windowID: shownWindowID) { return }
        Notifier.shared.post(
            id: Self.notificationID(key), title: session.title, subtitle: unread.label ?? session.groupName,
            body: unread.kind.notificationBody, sessionID: key.sessionID, windowID: unread.windowID,
            sound: AttentionSettings.notificationSound
        )
        logger.info("notified \(Self.notificationID(key), privacy: .public): \(unread.kind.rawValue, privacy: .public)")
    }

    /// What the pane shows counts as seen after a second in front of you.
    private func scheduleSeen() {
        seenTask?.cancel()
        guard inFront, let sessionID = shownSessionID, state.hasUnread(sessionID: sessionID) else { return }
        seenTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, inFront, shownSessionID == sessionID else { return }
            apply { $0.seen(sessionID: sessionID, windowID: shownWindowID) }
        }
    }

    private static func notificationID(_ key: AttentionKey) -> String {
        "\(key.sessionID)|\(key.paneID ?? "")"
    }

    // MARK: Saved

    private static let defaultsKey = "attention"

    private static func saved() -> AttentionState {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let snapshot = try? JSONDecoder().decode(AttentionState.Snapshot.self, from: data)
        else { return AttentionState() }
        return AttentionState(snapshot: snapshot)
    }
}
