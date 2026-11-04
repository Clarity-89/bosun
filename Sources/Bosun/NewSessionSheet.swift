import AppKit
import BosunCore
import SwiftUI

/// The New Session dialog. Create adds the session, starts it and attaches
/// it in the pane; a refused add keeps the dialog open with agent-deck's
/// message.
@MainActor
struct NewSessionSheet: View {
    let model: DeckModel

    @State private var group: GroupChoice
    /// The name typed for `.new`.
    @State private var newGroupName = ""
    @FocusState private var isNamingGroup: Bool
    @State private var title = ""
    /// The group's, shown until a directory is typed or chosen.
    @State private var groupDirectory: String
    @State private var editedDirectory: String?
    @State private var command: String
    @State private var sandbox = false
    @State private var worktree = false
    /// Nil while the branch follows the title.
    @State private var editedBranch: String?
    @State private var newBranch = true
    @State private var runsSetup = true
    @State private var error: String?
    @State private var isCreating = false

    init(model: DeckModel, prompt: NewSessionPrompt) {
        self.model = model
        _group = State(initialValue: .existing(prompt.groupPath))
        _groupDirectory = State(initialValue: prompt.directory)
        _command = State(initialValue: prompt.command)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                groupPicker
                TextField("Title", text: $title, prompt: Text(folderName))
                LabeledContent("Directory") {
                    HStack {
                        TextField("Directory", text: directory)
                            .labelsHidden()
                        Button("Choose…", action: chooseDirectory)
                    }
                }
                TextField("Command", text: $command, prompt: Text("Plain shell"))
                    .font(.body.monospaced())
                Text("agent-deck picks the harness from the command: claude, codex, omp, … Anything else, or nothing, runs in a plain shell.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Run in a Docker container", isOn: $sandbox)
                    .help("agent-deck's Docker sandbox: the command runs in a container, and this directory is mounted at /workspace. agent-deck removes the container with the session.")
                if let sandboxCaveat {
                    Text(sandboxCaveat)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Create in a git worktree", isOn: $worktree)
                TextField("Branch", text: branch)
                    .disabled(!worktree)
                Toggle("New branch", isOn: worktreeOption($newBranch))
                    .disabled(!worktree)
                Toggle("Run the worktree setup script", isOn: worktreeOption($runsSetup))
                    .disabled(!worktree)
                    .help("The repository's .agent-deck/worktree-setup.sh, once you have approved it with agent-deck worktree trust-hooks")
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
        // The list behind the dialog goes on; a group that vanished from it
        // gives way to the first, as when the dialog opened.
        .onChange(of: model.deckGroups) { _, groups in
            if case .existing(let path) = group {
                group = .existing(DeckGroup.listedPath(path, in: groups))
            }
        }
        // A group brings its own directory, which for a worktree waits on
        // agent-deck; of two switches in quick succession the later wins.
        .onChange(of: group) { _, choice in
            guard case .existing(let path) = choice else { return }
            Task {
                let directory = await model.newSessionDirectory(inGroup: path)
                if group == choice { groupDirectory = directory }
            }
        }
    }

    /// A group agent-deck lists, or one to create, which `add` does when a
    /// session names a group it does not have.
    private enum GroupChoice: Hashable {
        case existing(String)
        case new
    }

    private var groupPath: String {
        switch group {
        case .existing(let path): path
        case .new: newGroupName.trimmingCharacters(in: .whitespaces)
        }
    }

    @ViewBuilder
    private var groupPicker: some View {
        if model.deckGroups.isEmpty {
            LabeledContent("Group") {
                Text("agent-deck's default")
                    .foregroundStyle(.secondary)
            }
        } else {
            Picker("Group", selection: $group) {
                ForEach(model.deckGroups) { group in
                    Text(group.label).tag(GroupChoice.existing(group.path))
                }
                Divider()
                Text("New Group…").tag(GroupChoice.new)
            }
            if group == .new {
                TextField("Group name", text: $newGroupName, prompt: Text("New group"))
                    .focused($isNamingGroup)
                    .onAppear { isNamingGroup = true }
            }
        }
    }

    private var directory: Binding<String> {
        Binding(get: { editedDirectory ?? groupDirectory }, set: { editedDirectory = $0 })
    }

    private var folderName: String {
        let path = directory.wrappedValue.trimmingCharacters(in: .whitespaces)
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

    /// agent-deck runs the command alone in the container: with none, the
    /// pane dies at start and the container stays behind, so Create waits
    /// for one. A command the built-in image lacks dies the same way, which
    /// is worth saying before Create rather than after; which tool a
    /// command names is agent-deck's call, so the caption names the image's
    /// tools and leaves the match to you.
    private var sandboxCaveat: String? {
        guard sandbox else { return nil }
        guard hasCommand else { return "A command is needed: the container runs it, and nothing else." }
        return "agent-deck's built-in image has claude, codex, gemini, opencode and omp; a command it lacks dies at start, unless docker.default_image names an image that has it."
    }

    private var hasCommand: Bool { !command.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Off while there is no worktree for it to apply to, so a disabled
    /// row does not claim what Create will not do; the choice waits for
    /// the worktree to be switched back on.
    private func worktreeOption(_ choice: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { worktree && choice.wrappedValue }, set: { choice.wrappedValue = $0 })
    }

    private var canCreate: Bool {
        !directory.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty
            && (!worktree || !branch.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            && !(group == .new && groupPath.isEmpty)
            && (!sandbox || hasCommand)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: (directory.wrappedValue as NSString).expandingTildeInPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        directory.wrappedValue = (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func create() {
        let request = NewSessionRequest(
            title: title,
            directory: directory.wrappedValue,
            groupPath: groupPath,
            command: command,
            worktreeBranch: worktree ? branch.wrappedValue : nil,
            createBranch: newBranch,
            runsWorktreeSetup: runsSetup,
            sandbox: sandbox
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
