import BosunCore
import BosunTerminal
import Foundation
import Observation

/// Two shells for a session's directory, one above the other, for what a
/// project runs while you work on it, such as its frontend and backend.
/// Sessions in one directory share its pair. The terminals live here rather
/// than in a view: they run on while another session's show, or none, and
/// end with the last session in their directory.
@MainActor
@Observable
final class SideTerminals {
    /// By directory, top to bottom; nil where the shell has ended.
    private(set) var panes: [String: [TerminalPane?]] = [:]

    /// Whether a shell runs in the directory, shown or not.
    func hasShells(in directory: String) -> Bool {
        panes[directory]?.contains { $0 != nil } ?? false
    }

    /// Starts the directory's two shells, unless they run already.
    func start(in directory: String) {
        guard panes[directory] == nil else { return }
        panes[directory] = [launch(in: directory, at: 0), launch(in: directory, at: 1)]
    }

    /// A new shell in place of one that ended.
    func respawn(_ index: Int, in directory: String) {
        guard let pair = panes[directory], pair.indices.contains(index), pair[index] == nil else { return }
        panes[directory]?[index] = launch(in: directory, at: index)
    }

    /// Ends the shells of directories no session has any more: nothing
    /// could show them again.
    func listed(_ sessions: [DeckSession]) {
        let live = Set(sessions.map(\.path))
        for (directory, pair) in panes where !live.contains(directory) {
            panes[directory] = nil
            for terminal in pair { terminal?.teardown() }
        }
    }

    private func launch(in directory: String, at index: Int) -> TerminalPane {
        // Smaller than the session's terminal: two of them share a narrow column.
        let terminal = TerminalPane(command: AgentDeckCLI.userShell, environment: [:], workingDirectory: directory, fontSizeOffset: -2)
        terminal.yieldsKeyEquivalent = { Shortcut.menuAction(for: $0) != nil }
        terminal.onProcessExit = { [weak self, weak terminal] _ in
            guard let self, let terminal, let pair = panes[directory], pair[index] === terminal else { return }
            panes[directory]?[index] = nil
            // The engine reports the end from inside its own callback, which
            // has to return before the surface goes; so it goes after.
            Task { terminal.teardown() }
        }
        return terminal
    }
}
