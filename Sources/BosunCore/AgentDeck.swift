import Foundation

/// agent-deck, and the tmux its sessions run on, as Bosun's session model
/// uses them. `AgentDeckCLI` answers over the command line; a test answers
/// from memory, so the model's rules can be checked without a tmux server
/// or an agent-deck install. Calls that cannot fail usefully, the view and
/// pane housekeeping, answer with nothing or a safe default instead of
/// throwing, as the CLI does.
public protocol AgentDeck: Sendable {
    // MARK: agent-deck itself

    func binary() async throws -> AgentDeckBinary
    func statusEventsEnabled() async throws -> Bool
    func eventsStats() async throws -> EventsStats
    /// `session.status` frames after `cursor`. Ends only by cancellation or
    /// with an error; the caller resyncs from `eventsStats()` on
    /// `AgentDeckCLI.isCursorTooOld`.
    func follow(after cursor: UInt64) async throws -> any AsyncSequence<BusFrame, any Error> & Sendable
    /// Returns the installed launchd plist's path.
    func installNotifyDaemon() async throws -> String
    func openGhosttyAttach(sessionID: String) async throws

    // MARK: Sessions and groups

    func list() async throws -> [DeckSession]
    func groups() async throws -> [DeckGroup]
    func addSession(_ request: NewSessionRequest) async throws -> AddedSession
    func startSession(id: String) async throws
    func stopSession(id: String) async throws
    func restartSession(id: String) async throws
    func runWorktreeSetup(sessionID: String) async throws
    /// The repository agent-deck made the session's worktree from.
    func worktreeRepository(sessionID: String) async throws -> String
    func renameSession(id: String, to title: String) async throws
    func deleteSession(id: String) async throws
    func deleteGroup(path: String) async throws
    func moveSession(id: String, _ placement: RowPlacement) async throws
    func moveGroup(path: String, _ placement: RowPlacement) async throws

    // MARK: Windows and panes

    func listAllWindows() async throws -> WindowListing
    func pollPanes() async -> PanePoll?
    func newShellWindow(tmuxSession: String, workingDirectory: String?) async throws
    func splitShellPane(tmuxSession: String, direction: SplitDirection, workingDirectory: String?) async throws
    func selectWindow(windowID: String) async throws
    func closeWindow(sessionID: String, windowID: String) async throws
    func renameWindow(windowID: String, to name: String) async throws
    func typeIntoAgent(_ line: String, tmuxSession: String) async throws

    // MARK: Bosun's views

    func createView(_ view: String, grouping tmuxSession: String, directory: String?) async throws
    func selectWindow(_ windowID: String?, inView view: String) async throws
    func killView(_ view: String) async
    func killOrphanViews() async
    func updateServerEnvironment() async
    func loneViews() async -> Set<String>
    func someoneElseOnWindow(ofView view: String) async -> Bool
    func setSizesWindow(_ sizes: Bool, view: String) async
    func viewAttachLaunch(_ view: String, yieldsSize: Bool) throws -> AttachLaunch
    /// `session attach` through agent-deck, for a session Bosun has no
    /// view of.
    func attachLaunch(_ binary: AgentDeckBinary, sessionID: String) -> AttachLaunch
}
