import AppKit
import BosunTerminal
import SwiftUI

/// The side terminals, one above the other. The side pane and the sidebar's
/// Terminal tab both show this; the shells start the first time it shows.
@MainActor
struct SideTerminalsView: View {
    let terminals: SideTerminals
    /// Where the shells start: the shown session's directory.
    let directory: String?

    var body: some View {
        VSplitView {
            ForEach(terminals.panes.indices, id: \.self) { index in
                Group {
                    if let terminal = terminals.panes[index] {
                        BorrowedTerminalHost(terminal: terminal)
                    } else {
                        ContentUnavailableView {
                            Label("Shell ended", systemImage: "terminal")
                        } actions: {
                            Button("New Shell") { terminals.respawn(index) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 100, maxHeight: .infinity)
            }
        }
        .onAppear { terminals.startIfNeeded(in: directory) }
    }
}

/// Shows a terminal the model owns, for as long as the view is up. Where
/// TerminalHost's pane ends with its view, this one leaves hidden, its
/// shell still running, for the next view to take up.
private struct BorrowedTerminalHost: NSViewRepresentable {
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

/// Holds one borrowed terminal. Another slot may take it first: SwiftUI can
/// build the view a terminal moves to before it takes down the one it left.
private final class TerminalSlot: NSView {
    private var terminal: TerminalPane?

    func hold(_ terminal: TerminalPane) {
        guard terminal.superview !== self else { return }
        release()
        terminal.frame = bounds
        terminal.autoresizingMask = [.width, .height]
        addSubview(terminal)
        terminal.setShown(true)
        self.terminal = terminal
    }

    func release() {
        guard let terminal else { return }
        self.terminal = nil
        guard terminal.superview === self else { return }
        terminal.setShown(false)
        terminal.removeFromSuperview()
    }
}
