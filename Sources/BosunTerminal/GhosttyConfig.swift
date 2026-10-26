// Config loading follows Calyx's GhosttyConfigManager (MIT, see
// Vendored/CALYX-LICENSE) minus its glass preset and runtime overrides.

import GhosttyKit
import os

private let logger = Logger(subsystem: "com.bosun.Bosun", category: "GhosttyConfig")

/// Owns one `ghostty_config_t`: the user's own Ghostty configuration
/// (`~/.config/ghostty/config` and its includes), so the embedded terminal
/// looks exactly like the user's Ghostty.app.
@MainActor
final class GhosttyConfigManager {
    nonisolated(unsafe) let config: ghostty_config_t

    /// Nil when `ghostty_config_new` fails; `ghostty_init` must have run first.
    init?() {
        guard let config = GhosttyFFI.configNew() else {
            logger.critical("ghostty_config_new failed")
            return nil
        }
        GhosttyFFI.configLoadDefaultFiles(config)
        GhosttyFFI.configLoadRecursiveFiles(config)
        GhosttyFFI.configFinalize(config)
        for index in 0..<GhosttyFFI.configDiagnosticsCount(config) {
            let message = String(cString: GhosttyFFI.configGetDiagnostic(config, index: index).message)
            logger.warning("config diagnostic: \(message, privacy: .public)")
        }
        self.config = config
    }

    /// `abnormal-command-exit-runtime`: the engine treats an exit at or
    /// under this many milliseconds as a failure and reports it.
    var abnormalExitRuntimeMs: UInt64 {
        var value: UInt32 = 250
        let key = "abnormal-command-exit-runtime"
        _ = key.withCString { GhosttyFFI.configGet(config, &value, $0, UInt(key.utf8.count)) }
        return UInt64(value)
    }

    deinit {
        GhosttyFFI.configFree(config)
    }
}
