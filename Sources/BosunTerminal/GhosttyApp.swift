// Runtime wiring follows Calyx's GhosttyAppController (MIT, see
// Vendored/CALYX-LICENSE): six C callbacks, wakeups hop to the main queue
// asynchronously, actions enter the main actor synchronously.

@preconcurrency import AppKit
import GhosttyKit
import os

private let logger = Logger(subsystem: "com.bosun.Bosun", category: "GhosttyApp")

/// Owns the single `ghostty_app_t` and the config it was created with.
@MainActor
final class GhosttyAppController {
    static let shared = GhosttyAppController()

    enum Readiness { case ready, error(String) }

    private(set) var readiness: Readiness = .error("not started")
    nonisolated(unsafe) private(set) var app: ghostty_app_t? = nil
    private(set) var configManager: GhosttyConfigManager
    private var configFileWatcher: ConfigFileWatcher?
    private var appearanceObservation: NSKeyValueObservation?
    /// Every live surface, for config and colour-scheme fan-out.
    private var surfaces = NSHashTable<GhosttySurfaceController>.weakObjects()

    private init() {
        GhosttyResources.applyEnvironment()
        configManager = GhosttyConfigManager()
        guard GhosttyFFI.initialize() else {
            readiness = .error("ghostty_init failed")
            return
        }
        guard configManager.isLoaded, let config = configManager.config else {
            readiness = .error("ghostty config failed to load")
            return
        }
        var runtimeConfig = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: ghosttyWakeupCallback,
            action_cb: ghosttyActionCallback,
            read_clipboard_cb: ghosttyReadClipboardCallback,
            confirm_read_clipboard_cb: ghosttyConfirmReadClipboardCallback,
            write_clipboard_cb: ghosttyWriteClipboardCallback,
            close_surface_cb: ghosttyCloseSurfaceCallback
        )
        guard let newApp = GhosttyFFI.appNew(&runtimeConfig, config: config) else {
            readiness = .error("ghostty_app_new failed")
            return
        }
        app = newApp
        readiness = .ready
        GhosttyFFI.appSetFocus(newApp, focused: NSApp.isActive)

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(keyboardSelectionDidChange),
                           name: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(applicationDidBecomeActive),
                           name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(applicationDidResignActive),
                           name: NSApplication.didResignActiveNotification, object: nil)

        configFileWatcher = ConfigFileWatcher { [weak self] in self?.reloadConfig() }
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] application, _ in
            MainActor.assumeIsolated {
                self?.applyColorScheme(GhosttyColorScheme.scheme(for: application.effectiveAppearance))
            }
        }
        logger.info("libghostty ready")
    }

    func tick() {
        guard let app else { return }
        GhosttyFFI.appTick(app)
    }

    func register(_ surface: GhosttySurfaceController) {
        surfaces.add(surface)
    }

    /// Reloads the user's Ghostty config and pushes it to every surface;
    /// a config that fails to parse keeps the previous one.
    func reloadConfig() {
        guard let app else { return }
        let fresh = GhosttyConfigManager()
        guard fresh.isLoaded, let config = fresh.config else {
            logger.warning("config reload failed; keeping previous config")
            return
        }
        let previous = configManager
        configManager = fresh
        withExtendedLifetime((previous, fresh)) {
            GhosttyFFI.appUpdateConfig(app, config: config)
            for surface in surfaces.allObjects {
                surface.updateConfig(config)
            }
        }
    }

    private func applyColorScheme(_ scheme: ghostty_color_scheme_e) {
        guard let app else { return }
        GhosttyColorSchemeBroadcaster.broadcast(
            scheme,
            setAppScheme: { GhosttyFFI.appSetColorScheme(app, scheme: $0) },
            receivers: surfaces.allObjects
        )
    }

    @objc private func keyboardSelectionDidChange(_ notification: Notification) {
        guard let app else { return }
        GhosttyFFI.appKeyboardChanged(app)
    }

    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        guard let app else { return }
        GhosttyFFI.appSetFocus(app, focused: true)
    }

    @objc private func applicationDidResignActive(_ notification: Notification) {
        guard let app else { return }
        GhosttyFFI.appSetFocus(app, focused: false)
    }

    static func surfaceView(from surface: ghostty_surface_t) -> SurfaceView? {
        guard let ud = GhosttyFFI.surfaceUserdata(surface) else { return nil }
        return Unmanaged<SurfaceView>.fromOpaque(ud).takeUnretainedValue()
    }

    static func surfaceView(fromUserdata userdata: UnsafeMutableRawPointer) -> SurfaceView {
        Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }

    static func appController(from userdata: UnsafeMutableRawPointer) -> GhosttyAppController {
        Unmanaged<GhosttyAppController>.fromOpaque(userdata).takeUnretainedValue()
    }
}

// MARK: - C callbacks (file-level functions so they can be @convention(c))

/// Called from an arbitrary thread; returns nothing, so it hops asynchronously.
private func ghosttyWakeupCallback(_ userdata: UnsafeMutableRawPointer?) {
    guard let userdata else { return }
    nonisolated(unsafe) let ud = userdata
    DispatchQueue.main.async {
        GhosttyAppController.appController(from: ud).tick()
    }
}

/// Called on the main thread during tick and must return, so it enters the
/// main actor synchronously.
private func ghosttyActionCallback(_ app: ghostty_app_t?, _ target: ghostty_target_s, _ action: ghostty_action_s) -> Bool {
    guard let app else { return false }
    nonisolated(unsafe) let safeApp = app
    let safeTarget = target
    let safeAction = action
    return MainActor.assumeIsolated {
        GhosttyActionRouter.handleAction(app: safeApp, target: safeTarget, action: safeAction)
    }
}

private func ghosttyReadClipboardCallback(_ userdata: UnsafeMutableRawPointer?, _ location: ghostty_clipboard_e, _ state: UnsafeMutableRawPointer?) -> Bool {
    guard let userdata else { return false }
    nonisolated(unsafe) let safeUserdata = userdata
    nonisolated(unsafe) let safeState = state
    MainActor.assumeIsolated {
        let view = GhosttyAppController.surfaceView(fromUserdata: safeUserdata)
        guard let surface = view.surfaceController?.surface else { return }
        let pasteboard: NSPasteboard = location == GHOSTTY_CLIPBOARD_SELECTION
            ? NSPasteboard(name: NSPasteboard.Name("com.bosun.selection"))
            : .general
        let text = pasteboard.string(forType: .string) ?? ""
        text.withCString { ptr in
            GhosttyFFI.surfaceCompleteClipboardRequest(surface, data: ptr, state: safeState, confirmed: false)
        }
    }
    return true
}

/// libghostty asks before pasting text it considers unsafe (newlines,
/// bracketed-paste terminators). The pane hosts a tmux client where
/// multi-line pastes are routine, so the paste proceeds as requested.
private func ghosttyConfirmReadClipboardCallback(_ userdata: UnsafeMutableRawPointer?, _ string: UnsafePointer<CChar>?, _ state: UnsafeMutableRawPointer?, _ request: ghostty_clipboard_request_e) {
    guard let userdata else { return }
    nonisolated(unsafe) let safeUserdata = userdata
    nonisolated(unsafe) let safeState = state
    let contents = string.map { String(cString: $0) } ?? ""
    MainActor.assumeIsolated {
        let view = GhosttyAppController.surfaceView(fromUserdata: safeUserdata)
        guard let surface = view.surfaceController?.surface else { return }
        contents.withCString { ptr in
            GhosttyFFI.surfaceCompleteClipboardRequest(surface, data: ptr, state: safeState, confirmed: true)
        }
    }
}

private func ghosttyWriteClipboardCallback(_ userdata: UnsafeMutableRawPointer?, _ location: ghostty_clipboard_e, _ contents: UnsafePointer<ghostty_clipboard_content_s>?, _ contentsLen: Int, _ confirm: Bool) {
    guard let contents, contentsLen > 0 else { return }
    var value: String?
    for i in 0..<contentsLen {
        let entry = contents[i]
        if let mime = entry.mime, let data = entry.data, String(cString: mime) == "text/plain" {
            value = String(cString: data)
            break
        }
    }
    if value == nil, let data = contents[0].data {
        value = String(cString: data)
    }
    guard let value else { return }
    MainActor.assumeIsolated {
        let pasteboard: NSPasteboard = location == GHOSTTY_CLIPBOARD_SELECTION
            ? NSPasteboard(name: NSPasteboard.Name("com.bosun.selection"))
            : .general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(value, forType: .string)
    }
}

private func ghosttyCloseSurfaceCallback(_ userdata: UnsafeMutableRawPointer?, _ processAlive: Bool) {
    guard let userdata else { return }
    nonisolated(unsafe) let safeUserdata = userdata
    MainActor.assumeIsolated {
        GhosttyAppController.surfaceView(fromUserdata: safeUserdata).onProcessExit?()
    }
}
