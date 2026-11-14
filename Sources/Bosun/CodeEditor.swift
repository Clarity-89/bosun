import AppKit
import SwiftUI

/// A code editor a session's directory opens in: OpenIDEA or GoLand,
/// whichever are installed. The directory goes to the editor through
/// LaunchServices, as a folder dropped on its Dock icon does, so a running
/// editor gets a window and no second copy starts; whether that window is
/// new or the current one is the editor's own setting, which GoLand asks
/// about by default.
@MainActor
struct CodeEditor {
    /// The app bundle's name, as the Finder shows it.
    let name: String
    /// The app's icon at toolbar size.
    let icon: NSImage
    private let url: URL

    /// The installed editors, the default first. Looked up once; an editor
    /// installed while Bosun runs shows after a relaunch.
    static let installed: [CodeEditor] = ["ai.l0ng.openidea", "com.jetbrains.goland"].compactMap { bundleID in
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        return CodeEditor(name: url.deletingPathExtension().lastPathComponent, icon: icon, url: url)
    }

    func open(directory: String) async throws {
        try await open(URL(fileURLWithPath: directory, isDirectory: true))
    }

    func open(_ url: URL) async throws {
        _ = try await NSWorkspace.shared.open([url], withApplicationAt: self.url, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Opens in the default editor on a click, and in any installed one from
/// its menu.
@MainActor
struct CodeEditorButton: View {
    let help: (CodeEditor) -> String
    let open: (CodeEditor) -> Void

    var body: some View {
        if let editor = CodeEditor.installed.first {
            Menu {
                ForEach(CodeEditor.installed, id: \.name) { editor in
                    Button { open(editor) } label: { label(editor) }
                }
            } label: {
                label(editor)
            } primaryAction: {
                open(editor)
            }
            .help(help(editor))
        }
    }

    private func label(_ editor: CodeEditor) -> some View {
        Label { Text("Open in \(editor.name)") } icon: { Image(nsImage: editor.icon) }
    }
}
