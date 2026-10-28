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
            Button("Rename…") { if let session { rename(session) } }
            Button("Delete…", role: .destructive) { if let session { confirmDelete(session) } }
        }
        .disabled(session.map { model.busySessionIDs.contains($0.id) } ?? true)
    }

    /// NSAlert, like the notify daemon offer: it presents the same from a
    /// context menu as from the menu bar.
    private func rename(_ session: DeckSession) {
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

    private func confirmDelete(_ session: DeckSession) {
        let pruneWorktree = model.mayPruneWorktree(session)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(session.title)”?"
        alert.informativeText = pruneWorktree
            ? "This stops all of its processes, deletes its git worktree if it has one, uncommitted changes included, and removes it from agent-deck. The agent's own conversation files are kept."
            : "This stops all of its processes and removes it from agent-deck. Its directory is kept because another session works in it. The agent's own conversation files are kept."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
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
