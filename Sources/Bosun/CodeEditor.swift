import AppKit

/// The code editor a session's directory opens in: GoLand, else Visual
/// Studio Code, else Cursor, whichever is installed. The directory goes to
/// the editor through LaunchServices, as a folder dropped on its Dock icon
/// does, so a running editor gets a window and no second copy starts;
/// whether that window is new or the current one is the editor's own
/// setting, which GoLand asks about by default.
@MainActor
struct CodeEditor {
    /// The app bundle's name, as the Finder shows it.
    let name: String
    /// The app's icon at toolbar size.
    let icon: NSImage
    private let url: URL

    /// Looked up once; an editor installed while Bosun runs shows after a relaunch.
    static let installed: CodeEditor? = {
        let bundleIDs = ["com.jetbrains.goland", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92"]
        guard let url = bundleIDs.lazy.compactMap(NSWorkspace.shared.urlForApplication(withBundleIdentifier:)).first else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        return CodeEditor(name: url.deletingPathExtension().lastPathComponent, icon: icon, url: url)
    }()

    func open(directory: String) async throws {
        _ = try await NSWorkspace.shared.open(
            [URL(fileURLWithPath: directory, isDirectory: true)],
            withApplicationAt: url, configuration: NSWorkspace.OpenConfiguration()
        )
    }
}
