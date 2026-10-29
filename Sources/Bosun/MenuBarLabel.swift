import AppKit
import SwiftUI

/// The helm, with the unread count beside it: a crowded, notched menu bar
/// hides items that do not fit, so every point of width costs visibility.
struct MenuBarLabel: View {
    let model: DeckModel
    @AppStorage(AttentionSettings.menuBarCount) private var showsCount = true

    var body: some View {
        let count = showsCount ? model.attention.count : 0
        Image(nsImage: Self.icon(count: count))
            .accessibilityLabel(count > 0 ? "Bosun, \(count) unread" : "Bosun")
    }

    /// A status item draws only a Label's icon, so the count goes into the
    /// image; a template one, which the menu bar tints. The helm alone is
    /// drawn into one too: a symbol image's alignment rect is half its
    /// height, and the menu bar can squash the helm into it.
    private static func icon(count: Int) -> NSImage {
        let helm = NSImage(systemSymbolName: "helm", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)) ?? NSImage()
        let text = count > 0 ? NSAttributedString(string: "\(count)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.black,
        ]) : nil
        let textSize = text?.size() ?? .zero
        let gap = text == nil ? 0 : 3.0
        let size = NSSize(
            width: ceil(helm.size.width + gap + textSize.width),
            height: ceil(max(helm.size.height, textSize.height))
        )
        let image = NSImage(size: size, flipped: false) { rect in
            helm.draw(in: NSRect(x: 0, y: (rect.height - helm.size.height) / 2, width: helm.size.width, height: helm.size.height))
            text?.draw(at: NSPoint(x: helm.size.width + gap, y: (rect.height - textSize.height) / 2))
            return true
        }
        image.isTemplate = true
        return image
    }
}
