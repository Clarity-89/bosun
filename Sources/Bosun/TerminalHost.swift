import AppKit
import BosunTerminal
import SwiftUI

/// Hosts the embedded terminal for the selected session. The representable
/// itself never leaves the hierarchy: a live PTY must not sit inside a
/// SwiftUI `if`, which would destroy and recreate the surface on every
/// flip. Session changes swap the child pane instead.
struct TerminalHost: NSViewRepresentable {
    struct Key: Equatable {
        let sessionID: String
        let launch: TerminalPane.Launch

        static func == (lhs: Key, rhs: Key) -> Bool { lhs.sessionID == rhs.sessionID }
    }

    let key: Key?
    let onTitleChange: (String, String) -> Void
    let onExit: (String) -> Void

    func makeNSView(context: Context) -> TerminalContainerView {
        TerminalContainerView()
    }

    func updateNSView(_ container: TerminalContainerView, context: Context) {
        container.show(key, onTitleChange: onTitleChange, onExit: onExit)
    }
}

@MainActor
final class TerminalContainerView: NSView {
    private var currentID: String?
    private var pane: TerminalPane?

    func show(_ key: TerminalHost.Key?, onTitleChange: @escaping (String, String) -> Void, onExit: @escaping (String) -> Void) {
        guard key?.sessionID != currentID else { return }
        pane?.removeFromSuperview()
        pane = nil
        currentID = key?.sessionID
        guard let key else { return }

        let pane = TerminalPane(launch: key.launch)
        pane.translatesAutoresizingMaskIntoConstraints = false
        pane.onTitleChange = { title in onTitleChange(key.sessionID, title) }
        pane.onProcessExit = { onExit(key.sessionID) }
        addSubview(pane)
        NSLayoutConstraint.activate([
            pane.leadingAnchor.constraint(equalTo: leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: trailingAnchor),
            pane.topAnchor.constraint(equalTo: topAnchor),
            pane.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        self.pane = pane
        DispatchQueue.main.async { pane.focusTerminal() }
    }
}
