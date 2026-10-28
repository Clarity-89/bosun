import AppKit
import BosunCore
import SwiftUI

/// A session's actions, the same in its row's context menu and the Session
/// menu: a shell here, Open in Ghostty, Stop and Restart, then Rename and
/// Delete, each with its shortcut. A stopped session has nothing to stop;
/// Restart starts it. With a window row selected, Delete closes the window,
/// as d does on the TUI's window rows. Nil while nothing is selected, which
/// leaves the items visible but disabled, as macOS menus do.
@MainActor
struct SessionActionItems: View {
    let model: DeckModel
    let session: DeckSession?
    var window: SessionWindow?

    var body: some View {
        Group {
            ShellActionItems(model: model, session: session)
            Divider()
            Button("Open in Ghostty", action: perform(.openInGhostty)).shortcut(.openInGhostty)
            Divider()
            if session?.status != .stopped {
                Button("Stop", action: perform(.stop)).shortcut(.stop)
            }
            Button("Restart", action: perform(.restart)).shortcut(.restart)
            Divider()
            Button("Rename…", action: perform(.rename)).shortcut(.rename)
            Button(window == nil ? "Delete…" : "Close Window…", role: .destructive, action: perform(.delete))
                .shortcut(.delete)
        }
        .disabled(session.map { model.busySessionIDs.contains($0.id) } ?? true)
    }

    /// A disabled item never runs its action, so nil only needs a closure.
    private func perform(_ action: Shortcut) -> @MainActor () -> Void {
        { [model, session, window] in if let session { action.run(on: session, window: window, model: model) } }
    }
}

/// The TUI's "open shell here" choices: a new window, or a split of the
/// active window, each with `$SHELL` in the session's directory. The TUI's
/// H splits side by side.
@MainActor
struct ShellActionItems: View {
    let model: DeckModel
    let session: DeckSession?

    var body: some View {
        Button {
            if let session { model.newShellWindow(in: session) }
        } label: {
            Label("New Shell Window", systemImage: "plus.rectangle")
        }
        Button {
            if let session { Shortcut.splitSideBySide.run(on: session, window: nil, model: model) }
        } label: {
            Label("Split Side by Side", systemImage: "rectangle.split.2x1")
        }
        .shortcut(.splitSideBySide)
        Button {
            if let session { model.split(session, .topAndBottom) }
        } label: {
            Label("Split Top and Bottom", systemImage: "rectangle.split.1x2")
        }
    }
}

extension Shortcut {
    /// What a session action does, from its menu item and its list key
    /// alike. Delete closes `window` instead when there is one.
    @MainActor
    func run(on session: DeckSession, window: SessionWindow?, model: DeckModel) {
        switch self {
        case .rename: SessionPrompts.rename(session, model: model)
        case .restart: model.restartSession(session)
        case .stop where session.status != .stopped: model.stopSession(session)
        case .delete:
            if let window {
                SessionPrompts.confirmClose(window, in: session, model: model)
            } else {
                SessionPrompts.confirmDelete(session, model: model)
            }
        case .splitSideBySide: model.split(session, .sideBySide)
        case .openInGhostty: model.openInGhostty(session)
        default: break
        }
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

    /// As the TUI asks before it kills a window: whatever runs there ends.
    static func confirmClose(_ window: SessionWindow, in session: DeckSession, model: DeckModel) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close “\(window.title)”?"
        alert.informativeText = "This ends the window and everything running in it. “\(session.title)” keeps running."
        // Not destructive, for Return, as in confirmDelete.
        alert.addButton(withTitle: "Close Window")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.closeWindow(window, in: session)
    }
}

/// The Session menu creates in the selected row's group and acts on the
/// session selected in the main window, or on its selected window row.
struct SessionCommands: Commands {
    let model: DeckModel

    var body: some Commands {
        CommandMenu("Session") {
            Group {
                Button("New Session…") { model.promptNewSession() }
                    .shortcut(.newSession)
                Button("Quick Session") { model.quickCreateSession() }
                    .shortcut(.quickSession)
            }
            .disabled(model.newSessionPrompt != nil)
            Divider()
            SessionActionItems(model: model, session: model.selectedSession, window: model.selectedWindow)
        }
    }
}
