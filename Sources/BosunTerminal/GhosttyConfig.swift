// Config loading follows Calyx's GhosttyConfigManager (MIT, see
// Vendored/CALYX-LICENSE) minus its glass preset and runtime overrides.

@preconcurrency import AppKit
import GhosttyKit
import os

private let logger = Logger(subsystem: "com.bosun.Bosun", category: "GhosttyConfig")

/// Owns one `ghostty_config_t`: the user's own Ghostty configuration
/// (`~/.config/ghostty/config` and its includes), so the embedded terminal
/// looks exactly like the user's Ghostty.app.
@MainActor
final class GhosttyConfigManager {
    nonisolated(unsafe) private(set) var config: ghostty_config_t? {
        didSet {
            if let old = oldValue, old != config {
                GhosttyFFI.configFree(old)
            }
        }
    }

    var isLoaded: Bool { config != nil }

    var diagnostics: [String] {
        guard let cfg = config else { return [] }
        return (0..<GhosttyFFI.configDiagnosticsCount(cfg)).map {
            String(cString: GhosttyFFI.configGetDiagnostic(cfg, index: $0).message)
        }
    }

    init() {
        config = Self.loadDefaultConfig()
    }

    init(clone source: ghostty_config_t) {
        config = GhosttyFFI.configClone(source)
    }

    deinit {
        if let config { GhosttyFFI.configFree(config) }
    }

    static func loadDefaultConfig() -> ghostty_config_t? {
        guard let cfg = GhosttyFFI.configNew() else {
            logger.critical("ghostty_config_new failed")
            return nil
        }
        GhosttyFFI.configLoadDefaultFiles(cfg)
        GhosttyFFI.configLoadRecursiveFiles(cfg)
        GhosttyFFI.configFinalize(cfg)
        let diagCount = GhosttyFFI.configDiagnosticsCount(cfg)
        for i in 0..<diagCount {
            let message = String(cString: GhosttyFFI.configGetDiagnostic(cfg, index: i).message)
            logger.warning("config diagnostic: \(message, privacy: .public)")
        }
        return cfg
    }

    func getBool(_ key: String, default defaultValue: Bool = false) -> Bool {
        guard let cfg = config else { return defaultValue }
        var value = defaultValue
        _ = key.withCString { GhosttyFFI.configGet(cfg, &value, $0, UInt(key.utf8.count)) }
        return value
    }

    func getString(_ key: String) -> String? {
        guard let cfg = config else { return nil }
        var v: UnsafePointer<Int8>? = nil
        let found = key.withCString { GhosttyFFI.configGet(cfg, &v, $0, UInt(key.utf8.count)) }
        guard found, let ptr = v else { return nil }
        return String(cString: ptr)
    }

    func getColor(_ key: String) -> ghostty_config_color_s? {
        guard let cfg = config else { return nil }
        var color = ghostty_config_color_s()
        let found = key.withCString { GhosttyFFI.configGet(cfg, &color, $0, UInt(key.utf8.count)) }
        return found ? color : nil
    }

    var backgroundColor: NSColor {
        guard let color = getColor("background") else { return .windowBackgroundColor }
        return NSColor(
            red: CGFloat(color.r) / 255.0,
            green: CGFloat(color.g) / 255.0,
            blue: CGFloat(color.b) / 255.0,
            alpha: 1.0
        )
    }
}
