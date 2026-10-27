import BosunCore
import BosunTerminal
import SwiftUI

/// The embedded terminal for one attached session. Give it `.id(sessionID)`:
/// SwiftUI then replaces the pane, and with it the PTY, only when the
/// session changes, never on other state.
struct TerminalHost: NSViewRepresentable {
    let launch: AttachLaunch
    /// Monotonic; each new value moves keyboard focus into the terminal.
    let focusRequest: Int
    let onTitleChange: (String) -> Void
    let onExit: () -> Void

    final class Coordinator {
        var handledFocusRequest: Int
        init(handledFocusRequest: Int) { self.handledFocusRequest = handledFocusRequest }
    }

    func makeCoordinator() -> Coordinator {
        // A request issued before this pane existed is not replayed into it.
        Coordinator(handledFocusRequest: focusRequest)
    }

    func makeNSView(context: Context) -> TerminalPane {
        let pane = TerminalPane(command: launch.command, environment: launch.environment)
        pane.onTitleChange = onTitleChange
        pane.onProcessExit = onExit
        return pane
    }
    func updateNSView(_ pane: TerminalPane, context: Context) {
        guard focusRequest != context.coordinator.handledFocusRequest else { return }
        context.coordinator.handledFocusRequest = focusRequest
        pane.focusTerminal()
    }

    /// SwiftUI drops the pane when the session changes; the engine surface
    /// must go with it, now, not whenever ARC gets around to it.
    static func dismantleNSView(_ pane: TerminalPane, coordinator: Coordinator) {
        pane.teardown()
    }
}
