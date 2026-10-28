import AppKit
import BosunCore
import SwiftUI

/// Stop and Restart, then Rename and Delete: the same items in a row's
/// context menu and the Session menu. A stopped session has nothing to stop;
/// Restart starts it. Nil while nothing is selected, which leaves the items
/// visible but disabled, as macOS menus do.
@MainActor
struct SessionActionItems: View {
    let model: DeckModel
    let session: DeckSession?

    var body: some View {
        Group {
            if session?.status != .stopped {
                Button("Stop", action: perform(model.stopSession))
            }
            Button("Restart", action: perform(model.restartSession))
            Divider()
            Button("Rename…", action: perform { SessionPrompts.rename($0, model: model) })
            Button("Delete…", role: .destructive, action: perform { SessionPrompts.confirmDelete($0, model: model) })
        }
        .disabled(session.map { model.busySessionIDs.contains($0.id) } ?? true)
    }

    /// A disabled item never runs its action, so nil only needs a closure.
    private func perform(_ action: @escaping @MainActor (DeckSession) -> Void) -> @MainActor () -> Void {
        { if let session { action(session) } }
    }
}

/// NSAlert, like the notify daemon offer: the menus and the row's hover
/// buttons present the same prompt.
@MainActor
enum SessionPrompts {
    static func rename(_ session: DeckSession, model: DeckModel) {
        let alert = NSAlert()
        alert.messageText = "Rename “\(session.title)”"
        let field = NSTextField(string: session.title)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != session.title else { return }
        model.renameSession(session, to: title)
    }

    static func confirmDelete(_ session: DeckSession, model: DeckModel) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(session.title)”?"
        alert.informativeText = "This stops all of its processes, deletes its git worktree if it has one and no other session works in it, uncommitted changes included, and removes it from agent-deck. The agent's own conversation files are kept."
        // Not marked destructive: NSAlert then withholds Return from it, and
        // d then Return must delete, as d then y does in the TUI. The warning
        // style and the text carry the risk; Escape still cancels.
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.deleteSession(session)
    }
}

/// The Session menu creates in the selected row's group and acts on the
/// session selected in the main window.
struct SessionCommands: Commands {
    let model: DeckModel

    var body: some Commands {
        CommandMenu("Session") {
            Group {
                Button("New Session…") { model.promptNewSession() }
                    .keyboardShortcut("n")
                Button("Quick Session") { model.quickCreateSession() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            .disabled(model.newSessionPrompt != nil)
            Divider()
            SessionActionItems(model: model, session: model.selectedSession)
        }
    }
}
