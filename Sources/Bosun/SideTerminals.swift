import BosunCore
import BosunTerminal
import Foundation
import Observation

/// Two shells beside the sessions, one above the other, for what a project
/// runs while you work on it, such as its frontend and backend. They start
/// the first time they show, in the directory of the session shown. The
/// terminals live here rather than in a view: they run on while nothing
/// shows them, and move with the view between the side pane and the sidebar.
@MainActor
@Observable
final class SideTerminals {
    /// Top to bottom; nil where the shell has ended.
    private(set) var panes: [TerminalPane?] = []
    /// Where the first shells started; later ones start there too.
    @ObservationIgnored private var directory = FileManager.default.homeDirectoryForCurrentUser.path

    /// Starts both shells the first time; `directory` nil leaves them in
    /// the home directory.
    func startIfNeeded(in directory: String?) {
        guard panes.isEmpty else { return }
        if let directory, !directory.isEmpty { self.directory = directory }
        panes = [launch(), launch()]
    }

    /// A new shell in place of one that ended.
    func respawn(_ index: Int) {
        guard panes.indices.contains(index), panes[index] == nil else { return }
        panes[index] = launch()
    }

    private func launch() -> TerminalPane {
        // Smaller than the session's terminal: two of them share a narrow column.
        let terminal = TerminalPane(command: AgentDeckCLI.userShell, environment: [:], workingDirectory: directory, fontSizeOffset: -2)
        terminal.yieldsKeyEquivalent = { Shortcut.menuAction(for: $0) != nil }
        terminal.onProcessExit = { [weak self, weak terminal] _ in
            guard let self, let terminal else { return }
            ended(terminal)
        }
        return terminal
    }

    /// The engine reports the end from inside its own callback, which has
    /// to return before the surface goes; so it goes after.
    private func ended(_ terminal: TerminalPane) {
        guard let index = panes.firstIndex(where: { $0 === terminal }) else { return }
        panes[index] = nil
        Task { terminal.teardown() }
    }
}
