import AppKit
import BosunCore
import BosunTerminal
import SwiftUI

/// The embedded terminal for one attached pane. Identify it by the pane:
/// SwiftUI then replaces the PTY only for another pane, never on other
/// state. A hidden host keeps its tmux client and draws nothing.
struct TerminalHost: NSViewRepresentable {
    let launch: AttachLaunch
    let isShown: Bool
    /// Monotonic; each new value moves keyboard focus into the shown terminal.
    let focusRequest: Int
    let onTitleChange: (String) -> Void
    /// A key, click or scroll in the terminal.
    let onInput: () -> Void
    let onExit: (ProcessExit) -> Void
    /// The keyboard came into the terminal, or left it.
    let onFocusChange: (Bool) -> Void

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
        pane.onInput = onInput
        pane.onProcessExit = onExit
        pane.onFocusChange = onFocusChange
        pane.yieldsKeyEquivalent = TerminalPane.yieldsMenuKeys
        return pane
    }

    func updateNSView(_ pane: TerminalPane, context: Context) {
        pane.setShown(isShown)
        guard focusRequest != context.coordinator.handledFocusRequest else { return }
        // A hidden pane counts the request as seen, so showing it later
        // does not replay it.
        context.coordinator.handledFocusRequest = focusRequest
        if isShown { pane.focusTerminal() }
    }

    /// SwiftUI drops the pane once the model lets it go, and the model kills
    /// the pane's view as it does, which ends the tmux client. The surface
    /// goes once the client has: freeing it first deadlocks the main thread
    /// on a client that writes as it exits. A pane attached through
    /// agent-deck has no view to kill, and goes after the grace.
    static func dismantleNSView(_ pane: TerminalPane, coordinator: Coordinator) {
        pane.teardownAfterExit(grace: .seconds(5))
    }
}

extension TerminalPane {
    /// Whether a ⌘ key is the menu bar's: every terminal Bosun shows yields
    /// those to it, and the engine's keybinds get the rest.
    static let yieldsMenuKeys: (NSEvent) -> Bool = { Shortcut.menuAction(for: $0) != nil }

    /// A terminal Bosun runs itself, in a narrow column beside the session's
    /// and so smaller than it. The owner hears of the end in `onExit`, with
    /// the pane that ended, and the surface goes after that returns: the
    /// engine reports the end from inside its own callback.
    static func owned(command: String, directory: String, onExit: @escaping (TerminalPane, ProcessExit) -> Void) -> TerminalPane {
        let pane = TerminalPane(command: command, environment: [:], workingDirectory: directory, fontSizeOffset: -2)
        pane.yieldsKeyEquivalent = yieldsMenuKeys
        pane.onProcessExit = { [weak pane] exit in
            guard let pane else { return }
            onExit(pane, exit)
            Task { pane.teardown() }
        }
        return pane
    }
}

/// Shows a terminal the model owns, for as long as the view is up. Where
/// TerminalHost's pane ends with its view, this one leaves hidden, its
/// command still running, for the next view to take up.
struct BorrowedTerminalHost: NSViewRepresentable {
    let terminal: TerminalPane

    func makeNSView(context: Context) -> TerminalSlot {
        let slot = TerminalSlot()
        slot.hold(terminal)
        return slot
    }

    func updateNSView(_ slot: TerminalSlot, context: Context) {
        slot.hold(terminal)
    }

    static func dismantleNSView(_ slot: TerminalSlot, coordinator: ()) {
        slot.release()
    }
}

/// Holds one borrowed terminal. As the pane moves to a session in another
/// directory, SwiftUI keeps the slot and hands it that directory's
/// terminal, so the one leaving hides first.
final class TerminalSlot: NSView {
    private var terminal: TerminalPane?

    func hold(_ terminal: TerminalPane) {
        guard terminal !== self.terminal else { return }
        release()
        terminal.frame = bounds
        terminal.autoresizingMask = [.width, .height]
        // Shown first: focus asked for while it was out takes effect as it
        // enters the window, and must not land on a hidden view.
        terminal.setShown(true)
        addSubview(terminal)
        self.terminal = terminal
    }

    func release() {
        guard let terminal else { return }
        self.terminal = nil
        // SwiftUI may build a view's replacement before it dismantles the
        // view, and the new slot then holds the terminal already.
        guard terminal.superview === self else { return }
        terminal.setShown(false)
        terminal.removeFromSuperview()
    }
}
