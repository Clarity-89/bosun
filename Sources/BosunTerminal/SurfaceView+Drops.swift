import AppKit

/// Ghostty's drop handling (SurfaceView_AppKit.swift, NSPasteboard+Extension.swift
/// and Ghostty.Shell.swift on main): a file becomes its escaped path, anything
/// else its text, sent as a paste, so an agent behind tmux gets it as one
/// bracketed paste. The view registers `dropTypes` in its init.
extension SurfaceView {
    static let dropTypes: [NSPasteboard.PasteboardType] = [.string, .fileURL]

    private static let escapeCharacters = Set("\\ ()[]{}<>\"'`!#$&;|*?\t")

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        // Copy, for the badge: the dragged file stays where it is.
        sender.draggingPasteboard.availableType(from: Self.dropTypes) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let surfaceController, let text = Self.dropText(from: sender.draggingPasteboard) else { return false }
        onInput?()
        surfaceController.sendText(text)
        return true
    }

    /// Each item's file path, escaped for a shell, else its text, joined by
    /// spaces; nil when no item has either.
    static func dropText(from pasteboard: NSPasteboard) -> String? {
        let parts = (pasteboard.pasteboardItems ?? []).compactMap { item -> String? in
            if let plist = item.propertyList(forType: .fileURL),
               let url = NSURL(pasteboardPropertyList: plist, ofType: .fileURL) as URL?,
               url.isFileURL {
                return escape(url.path)
            }
            return item.string(forType: .string)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// A backslash before each character the shell would otherwise read.
    private static func escape(_ text: String) -> String {
        text.reduce(into: "") { escaped, character in
            if escapeCharacters.contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
    }
}
