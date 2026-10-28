import AppKit
import BosunCore
import SwiftUI

/// The New Session dialog. Create adds the session, starts it and attaches
/// it in the pane; a refused add keeps the dialog open with agent-deck's
/// message.
@MainActor
struct NewSessionSheet: View {
    let model: DeckModel

    /// Nil while loading.
    @State private var groups: [DeckGroup]?
    @State private var groupPath: String
    @State private var title = ""
    @State private var directory: String
    @State private var command: String
    @State private var worktree = false
    /// Nil while the branch follows the title.
    @State private var editedBranch: String?
    @State private var newBranch = true
    @State private var error: String?
    @State private var isCreating = false

    init(model: DeckModel, prompt: NewSessionPrompt) {
        self.model = model
        _groupPath = State(initialValue: prompt.groupPath)
        _directory = State(initialValue: prompt.directory)
        _command = State(initialValue: prompt.command)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                groupPicker
                TextField("Title", text: $title, prompt: Text(folderName))
                LabeledContent("Directory") {
                    HStack {
                        TextField("Directory", text: $directory)
                            .labelsHidden()
                        Button("Choose…", action: chooseDirectory)
                    }
                }
                TextField("Command", text: $command, prompt: Text("Plain shell"))
                    .font(.body.monospaced())
                Text("agent-deck picks the harness from the command: claude, codex, omp, … Anything else, or nothing, runs in a plain shell.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Create in a git worktree", isOn: $worktree)
                TextField("Branch", text: branch)
                    .disabled(!worktree)
                Toggle("New branch", isOn: $newBranch)
                    .disabled(!worktree)
                if let error {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
            .disabled(isCreating)
            .padding(20)
            Divider()
            HStack {
                if isCreating {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Cancel", role: .cancel) { model.dismissNewSession() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
            .disabled(isCreating)
            .padding(16)
        }
        .frame(width: 540)
        .task { await loadGroups() }
    }

    /// The popup is laid out while the list loads too, hidden under a
    /// pulsing skeleton of its size, so the row never changes height.
    @ViewBuilder
    private var groupPicker: some View {
        LabeledContent("Group") {
            if groups?.isEmpty == true {
                Text("agent-deck's default")
                    .foregroundStyle(.secondary)
            } else if groups == nil {
                groupMenu
                    .hidden()
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.quaternary)
                            .phaseAnimator([1, 0.4]) { $0.opacity($1) } animation: { _ in .easeInOut(duration: 0.8) }
                    }
            } else {
                groupMenu
            }
        }
    }

    private var groupMenu: some View {
        Picker("Group", selection: $groupPath) {
            if let groups {
                ForEach(groups) { group in
                    Text(group.label).tag(group.path)
                }
            } else {
                // Sizes the skeleton like the popup it stands in for.
                Text(groupPath.isEmpty ? "Loading" : groupPath).tag(groupPath)
            }
        }
        .labelsHidden()
    }

    private var folderName: String {
        let path = directory.trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? "" : URL(fileURLWithPath: (path as NSString).expandingTildeInPath).lastPathComponent
    }

    /// Follows the title, or the folder name without one, until edited, as
    /// in the TUI. agent-deck refuses what git would.
    private var branch: Binding<String> {
        Binding(
            get: {
                editedBranch ?? (title.isEmpty ? folderName : title)
                    .split(whereSeparator: \.isWhitespace)
                    .joined(separator: "-")
            },
            set: { editedBranch = $0 }
        )
    }

    private var canCreate: Bool {
        !directory.trimmingCharacters(in: .whitespaces).isEmpty
            && (!worktree || !branch.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// Selects the group the dialog opened on; any other, a group that is
    /// gone or none, falls back to the first.
    private func loadGroups() async {
        do {
            let loaded = try await model.loadGroups()
            if !loaded.contains(where: { $0.path == groupPath }) {
                groupPath = loaded.first?.path ?? ""
            }
            groups = loaded
        } catch {
            groups = []
            self.error = error.localizedDescription
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        directory = (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func create() {
        let request = NewSessionRequest(
            title: title,
            directory: directory,
            groupPath: groupPath,
            command: command,
            worktreeBranch: worktree ? branch.wrappedValue : nil,
            createBranch: newBranch
        )
        isCreating = true
        error = nil
        Task {
            do {
                try await model.createSession(request)
                model.dismissNewSession()
            } catch {
                self.error = error.localizedDescription
                isCreating = false
            }
        }
    }
}
