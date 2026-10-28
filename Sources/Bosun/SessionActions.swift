import AppKit
import BosunCore
import SwiftUI

/// Start, or Stop and Restart, then Rename and Delete: the same items in a
/// row's context menu and the Session menu. Nil while nothing is selected.
@MainActor
struct SessionActionItems: View {
    let model: DeckModel
    let session: DeckSession?

    var body: some View {
        Group {
            if let session, !session.status.hasProcess {
                Button("Start") { model.startSession(session) }
            } else {
                Button("Stop") { if let session { model.stopSession(session) } }
                Button("Restart") { if let session { model.restartSession(session) } }
            }
            Divider()
            Button("Rename…") { if let session { SessionPrompts.rename(session, model: model) } }
            Button("Delete…", role: .destructive) { if let session { SessionPrompts.confirmDelete(session, model: model) } }
        }
        .disabled(session.map { model.busySessionIDs.contains($0.id) } ?? true)
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
        let pruneWorktree = model.mayPruneWorktree(session)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(session.title)”?"
        alert.informativeText = pruneWorktree
            ? "This stops all of its processes, deletes its git worktree if it has one, uncommitted changes included, and removes it from agent-deck. The agent's own conversation files are kept."
            : "This stops all of its processes and removes it from agent-deck. Its directory is kept because another session works in it. The agent's own conversation files are kept."
        // Not marked destructive: NSAlert then withholds Return from it, and
        // d then Return must delete, as d then y does in the TUI. The warning
        // style and the text carry the risk; Escape still cancels.
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.deleteSession(session, pruneWorktree: pruneWorktree)
    }
}

/// The Session menu acts on the session selected in the main window.
struct SessionCommands: Commands {
    let model: DeckModel

    var body: some Commands {
        CommandMenu("Session") {
            SessionActionItems(model: model, session: model.selectedSession)
        }
    }
}
