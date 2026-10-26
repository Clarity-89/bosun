import Foundation

/// libghostty resolves its resources directory once at engine init
/// (terminfo for `TERM=xterm-ghostty`, shell integration scripts). Bosun
/// does not bundle them yet, so it points at the installed Ghostty.app,
/// which matches the embedded engine version (1.3.1).
enum GhosttyResources {
    static let candidates: [URL] = [
        Bundle.main.resourceURL?.appendingPathComponent("ghostty"),
        URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/Resources"),
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Ghostty.app/Contents/Resources"),
    ].compactMap { $0 }

    /// The first candidate holding a `shell-integration` directory, or nil.
    static func resolve() -> String? {
        for root in candidates {
            var isDirectory: ObjCBool = false
            let path = root.appendingPathComponent("shell-integration").path
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                return root.path
            }
        }
        return nil
    }

    /// Must run before `ghostty_init`; a bundled copy wins over any
    /// `GHOSTTY_RESOURCES_DIR` inherited from a Ghostty-hosted shell.
    static func applyEnvironment() {
        GhosttyResourcesDirEnvironment.apply(resolve())
    }
}
