import BosunCore
import BosunTerminal
import SwiftUI

/// The embedded terminal for one attached pane. Identify it by the pane:
/// SwiftUI then replaces the PTY only for another pane, never on other
/// state. A hidden host keeps its tmux client and draws nothing.
struct TerminalHost: NSViewRepresentable {
    let launch: AttachLaunch
    let isShown: Bool
    /// Whether the next input in the terminal goes to `onInput`.
    let awaitsInput: Bool
    /// Monotonic; each new value moves keyboard focus into the shown terminal.
    let focusRequest: Int
    let onTitleChange: (String) -> Void
    let onInput: () -> Void
    let onExit: (ProcessExit) -> Void

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
        pane.yieldsKeyEquivalent = { Shortcut.menuAction(for: $0) != nil }
        return pane
    }

    func updateNSView(_ pane: TerminalPane, context: Context) {
        pane.setShown(isShown)
        pane.onInput = onInput
        pane.setAwaitsInput(isShown && awaitsInput)
        guard focusRequest != context.coordinator.handledFocusRequest else { return }
        // A hidden pane counts the request as seen, so showing it later
        // does not replay it.
        context.coordinator.handledFocusRequest = focusRequest
        if isShown { pane.focusTerminal() }
    }

    /// SwiftUI drops the pane once the model lets it go; the engine surface
    /// must go with it, now, not whenever ARC gets around to it.
    static func dismantleNSView(_ pane: TerminalPane, coordinator: Coordinator) {
        pane.teardown()
    }
}
