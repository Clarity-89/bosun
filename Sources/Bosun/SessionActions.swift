import AppKit
import BosunCore
import SwiftUI

/// A session's actions, the same in its row's context menu and the Session
/// menu: a shell here, Open in Ghostty, the pull request and the merge to
/// ask its agent for, Stop and Restart, Mark as Unread, the issue it works
/// on, then Rename and Delete, each with its shortcut. A stopped session
/// has nothing to stop or to ask; Restart starts it. With a window row
/// selected, the items act on the window's session, and Delete closes the
/// window instead, as d does on the TUI's window rows. Nil while nothing
/// is selected, which leaves the items visible but disabled, as macOS
/// menus do.
@MainActor
struct SessionActionItems: View {
    let model: DeckModel
    let session: DeckSession?
    var window: SessionWindow?

    var body: some View {
        Group {
            ShellActionItems(model: model, session: session)
            Divider()
            Button("Open in Ghostty", action: perform(session, model.openInGhostty)).shortcut(.openInGhostty)
            Divider()
            if session?.status != .stopped {
                ForEach(AgentRequest.allCases, id: \.self) { request in
                    Button(request.menuTitle, action: perform(session) { model.ask(request, of: $0) })
                }
                Divider()
            }
            if session?.status != .stopped {
                Button("Stop…", action: perform(session) { SessionPrompts.confirmStop($0, model: model) }).shortcut(.stop)
            }
            Button("Restart", action: perform(session, model.restartSession)).shortcut(.restart)
            Divider()
            Button("Mark as Unread", action: perform(session) { model.attention.markUnread(sessionID: $0.id) })
            Divider()
            Button("Link to Issue…", action: perform(session) { SessionPrompts.linkIssue($0, model: model) })
            if let session, model.inbox[session].issue?.source == .linked {
                Button("Remove Issue Link", action: perform(session) { model.inbox.unlink(session: $0.id) })
            }
            Divider()
            Button("Rename…", action: perform(session) { SessionPrompts.rename($0, model: model) }).shortcut(.rename)
            if let window {
                Button("Close Window…", role: .destructive, action: perform(session) {
                    SessionPrompts.confirmClose(window, in: $0, model: model)
                })
                .shortcut(.delete)
            } else {
                Button("Delete…", role: .destructive, action: perform(session) {
                    SessionPrompts.confirmDelete($0, model: model)
                })
                .shortcut(.delete)
            }
        }
        .disabled(session.map { model.busySessions[$0.id] != nil } ?? true)
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
        Button(action: perform(session, model.newShellWindow)) {
            Label("New Shell Window", systemImage: "plus.rectangle")
        }
        Button(action: perform(session) { model.split($0, .sideBySide) }) {
            Label("Split Side by Side", systemImage: "rectangle.split.2x1")
        }
        .shortcut(.splitSideBySide)
        Button(action: perform(session) { model.split($0, .topAndBottom) }) {
            Label("Split Top and Bottom", systemImage: "rectangle.split.1x2")
        }
    }
}

/// The toolbar's requests to the selected session's agent, by name, each
/// outlined in GitHub's colour for what it ends in: nothing for a stopped
/// session, which has no agent, and disabled while an action runs on it,
/// as the menu's items are.
@MainActor
struct AgentRequestButtons: View {
    let model: DeckModel
    let session: DeckSession

    var body: some View {
        if session.status != .stopped {
            ForEach(AgentRequest.allCases, id: \.self) { request in
                Button(request.title) { model.ask(request, of: session) }
                    .tint(request.color)
                    .help(request.help)
            }
            .buttonStyle(OutlinedButtonStyle())
            .disabled(model.busySessions[session.id] != nil)
        }
    }
}

/// The tint as a hairline round the title, with the title in it; a light
/// wash of it under the pointer, more while pressed. The toolbar's own
/// styles fill the button or colour its text only.
private struct OutlinedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        OutlinedButton(configuration: configuration)
    }

    private struct OutlinedButton: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 7)
            configuration.label
                .font(.callout.weight(.medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .foregroundStyle(.tint)
                .background(.tint.opacity(configuration.isPressed ? 0.28 : isHovered ? 0.16 : 0), in: shape)
                .overlay(shape.strokeBorder(.tint.opacity(isHovered ? 1 : 0.6), lineWidth: 1))
                .contentShape(shape)
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { isHovered = $0 }
                .pointerStyle(.link)
                .animation(.easeOut(duration: 0.12), value: isHovered)
        }
    }
}

/// A menu item's action on `session`. A disabled item never runs its
/// action, so nil only needs a closure.
@MainActor
private func perform(_ session: DeckSession?, _ action: @escaping @MainActor (DeckSession) -> Void) -> @MainActor () -> Void {
    { if let session { action(session) } }
}

/// NSAlert, like the notify daemon offer: the menus, the list's keys and
/// the row's hover buttons present the same prompt.
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

    /// Your link wins over what Bosun works out, in Bosun only: GitHub is
    /// not told. `#12` means the session's repository, a fork's upstream.
    static func linkIssue(_ session: DeckSession, model: DeckModel) {
        let github = model.inbox[session]
        let alert = NSAlert()
        alert.messageText = "Link “\(session.title)” to an issue"
        alert.informativeText = github.issueRepo.map { "An issue URL, owner/repo#12, or #12 in \($0)." } ?? "An issue URL or owner/repo#12."
        let field = NSTextField(string: github.issue.map { $0.ref.description } ?? "")
        field.placeholderString = "https://github.com/owner/repo/issues/12"
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Link")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let ref = IssueRef(parsing: field.stringValue, defaultRepo: github.issueRepo) else {
            let error = NSAlert()
            error.messageText = "That is not an issue"
            error.informativeText = "“\(field.stringValue)” names no GitHub issue Bosun can find."
            error.runModal()
            return
        }
        model.inbox.link(ref, toSession: session.id)
    }

    static func confirmDelete(_ session: DeckSession, model: DeckModel) {
        confirm(
            "Delete “\(session.title)”?",
            "This stops all of its processes, deletes its git worktree if it has one and no other session works in it, uncommitted changes included, and removes it from agent-deck. The agent's own conversation files are kept.",
            button: "Delete"
        ) { model.deleteSession(session) }
    }

    /// As Delete asks for one session, for all of the group's at once; the
    /// count is what `deleteGroup` deletes, archived ones included.
    static func confirmDeleteGroup(_ group: SessionGroup, model: DeckModel) {
        let count = model.sessions(inGroupTree: group.path).count
        confirm(
            "Delete the group “\(group.name)” and its \(count == 1 ? "session" : "\(count) sessions")?",
            "Every session in it and its subgroups goes, archived ones included. Each stops all of its processes, deletes its git worktree if it has one and no other session works in it, uncommitted changes included, and leaves agent-deck. The agents' own conversation files are kept.",
            button: "Delete Group"
        ) { model.deleteGroup(group) }
    }

    /// As the TUI asks before D: the agent ends; the session stays listed,
    /// for Restart.
    static func confirmStop(_ session: DeckSession, model: DeckModel) {
        confirm(
            "Stop “\(session.title)”?",
            "This ends the agent and everything else running in the session. The session stays in the list; Restart starts it again.",
            button: "Stop"
        ) { model.stopSession(session) }
    }

    /// As the TUI asks before it kills a window: whatever runs there ends.
    static func confirmClose(_ window: SessionWindow, in session: DeckSession, model: DeckModel) {
        confirm(
            "Close “\(window.title)”?",
            "This ends the window and everything running in it. “\(session.title)” keeps running.",
            button: "Close Window"
        ) { model.closeWindow(window, in: session) }
    }

    /// A warning whose confirming button is not marked destructive: NSAlert
    /// then withholds Return from it, and d then Return must delete, as d
    /// then y does in the TUI. The style and the text carry the risk; Escape
    /// still cancels.
    private static func confirm(_ message: String, _ detail: String, button: String, then action: () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        action()
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
