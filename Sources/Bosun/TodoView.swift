import BosunCore
import SwiftUI

/// What the list half of the panel shows: the list the file describes, or
/// the markdown itself.
enum TodoMode: String {
    case preview, edit
}

/// The To-dos tab: the to-do list over its agent, in the sidebar, as it is
/// no one session's. Neither half depends on the other: the list reads and
/// writes the file whatever the agent does, and the agent edits the same
/// file with its own tools.
@MainActor
struct TodoPanel: View {
    let model: DeckModel
    /// Kept across launches: whoever edits the markdown keeps editing it.
    @AppStorage("todos.mode") private var mode = TodoMode.preview

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                list
                    // The list is what you read; the agent only answers in a line.
                    .frame(height: geometry.size.height * 0.7)
                Divider()
                TodoAgentView(agent: model.todoAgent)
            }
        }
        .onAppear {
            model.todos.start()
            model.todoAgent.start()
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch mode {
                case .preview:
                    TodoPreview(todos: model.todos)
                case .edit:
                    TodoEditor(todos: model.todos)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error = model.todos.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(verbatim: "\(model.todos.document.openCount) open")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let editor = CodeEditor.installed {
                Button {
                    model.openTodos(in: editor)
                } label: {
                    Label { Text("Open in \(editor.name)") } icon: { Image(nsImage: editor.icon) }
                }
                .help("Open \(model.todos.displayPath) in \(editor.name)")
            }
            Button {
                mode = mode == .preview ? .edit : .preview
            } label: {
                Label(mode == .preview ? "Edit Markdown" : "Show List", systemImage: mode == .preview ? "pencil" : "checklist")
            }
            .help(mode == .preview ? "Edit the list's markdown" : "Show the list as a checklist")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// omp's terminal, or why there is none, under a line that names it and
/// restarts it.
@MainActor
private struct TodoAgentView: View {
    let agent: TodoAgent

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Label("Agent", systemImage: "sparkles")
                    .help(agent.command ?? "omp, in \(agent.directory.path)")
                Spacer(minLength: 0)
                if case .running = agent.state {
                    Button("Restart") { agent.restart() }
                        .help("Start omp again; it picks up its last conversation")
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            Divider()
            Group {
                switch agent.state {
                case .idle, .launching:
                    ProgressView()
                case .running(let pane):
                    BorrowedTerminalHost(terminal: pane)
                case .ended(let exit):
                    ContentUnavailableView {
                        Label("Agent ended", systemImage: "sparkles")
                    } description: {
                        if exit == .abnormal, let command = agent.command {
                            Text("omp ended as it started. Run this in a terminal to see why:")
                            Text(verbatim: command)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        } else {
                            Text("Restart picks up its last conversation.")
                        }
                    } actions: {
                        Button("Restart") { agent.restart() }
                    }
                case .notInstalled:
                    ContentUnavailableView {
                        Label("omp not found", systemImage: "questionmark.app")
                    } description: {
                        Text("The to-do agent runs omp, which is not on your login shell's PATH. The list works without it.")
                    } actions: {
                        Button("Try Again") { agent.restart() }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The file as a list: headings, items with a checkbox that ticks the item
/// in the file, and the rest as text.
private struct TodoPreview: View {
    let todos: TodoStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(todos.document.lines.enumerated()), id: \.offset) { index, line in
                    TodoLineView(line: line, isFirst: index == 0) { todos.toggle(lineAt: index) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .overlay {
            if todos.document.isEmpty {
                ContentUnavailableView {
                    Label("No to-dos yet", systemImage: "checklist")
                } description: {
                    Text("Type them in the markdown, or ask the agent below. They live in \(todos.displayPath).")
                }
            }
        }
    }
}

private struct TodoLineView: View {
    let line: TodoDocument.Line
    let isFirst: Bool
    let toggle: () -> Void

    var body: some View {
        switch line {
        case .heading(let level, let title):
            Text(title)
                .font(level == 1 ? .title2.weight(.bold) : level == 2 ? .title3.weight(.semibold) : .headline)
                .padding(.top, isFirst ? 0 : 14)
                .padding(.bottom, 4)
        case .item(let done, let text, let indent):
            Toggle(isOn: Binding(get: { done }, set: { _ in toggle() })) {
                Text(inlineMarkdown: text)
                    .strikethrough(done)
                    .foregroundStyle(done ? .secondary : .primary)
            }
            .toggleStyle(.checkbox)
            .padding(.leading, CGFloat(indent) * 8)
        case .other(let text):
            if text.allSatisfy(\.isWhitespace) {
                Color.clear.frame(height: 4)
            } else {
                Text(inlineMarkdown: text)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The markdown itself, written to the file a moment after each change.
private struct TodoEditor: View {
    let todos: TodoStore

    var body: some View {
        TextEditor(text: Binding(get: { todos.document.text }, set: { todos.edit($0) }))
            .font(.system(.body, design: .monospaced))
            .padding(8)
    }
}

private extension Text {
    /// Markdown's emphasis, code and links in a line; the line as written
    /// where it is not markdown.
    init(inlineMarkdown text: String) {
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            self.init(attributed)
        } else {
            self.init(verbatim: text)
        }
    }
}
