import BosunCore
import BosunTerminal
import SwiftUI

/// The embedded terminal for one attached session. Give it `.id(sessionID)`:
/// SwiftUI then replaces the pane, and with it the PTY, only when the
/// session changes, never on other state.
struct TerminalHost: NSViewRepresentable {
    let launch: AttachLaunch
    let onTitleChange: (String) -> Void
    let onExit: () -> Void

    func makeNSView(context: Context) -> TerminalPane {
        let pane = TerminalPane(command: launch.command, environment: launch.environment)
        pane.onTitleChange = onTitleChange
        pane.onProcessExit = onExit
        return pane
    }

    func updateNSView(_ pane: TerminalPane, context: Context) {}
}
