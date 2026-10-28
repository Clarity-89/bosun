@preconcurrency import AppKit
import GhosttyKit
import os

private let logger = Logger(subsystem: "com.bosun.Bosun", category: "TerminalPane")

/// How a pane's command ended, by the engine's test.
public enum ProcessExit: Sendable {
    case normal
    /// Within `abnormal-command-exit-runtime`: the command never got going.
    /// On macOS the engine sees no exit code (its `login` wrapper hides it),
    /// so the runtime is the whole test.
    case abnormal
}

/// One embedded terminal running one command. The surface is created when
/// the view first lands in a window (libghostty needs the window's backing
/// scale) and freed with the view.
@MainActor
public final class TerminalPane: NSView {
    public var onTitleChange: ((String) -> Void)?
    /// The command ended or the engine closed the surface; the view is done.
    public var onProcessExit: ((ProcessExit) -> Void)?
    /// Whether a ⌘ key belongs to the app's menu bar, which then gets it
    /// before the engine's keybinds do; nil leaves every key to the engine.
    public var yieldsKeyEquivalent: ((NSEvent) -> Bool)?

    private let command: String
    private let environment: [String: String]
    private let surfaceView = SurfaceView(frame: .zero)
    private var started = false

    /// libghostty runs `command` as `sh -c "exec <command>"` through `login`.
    /// `environment` is added to the child's, with `TERM_PROGRAM` naming Bosun.
    public init(command: String, environment: [String: String]) {
        self.command = command
        var environment = environment
        environment["TERM_PROGRAM"] = "Bosun"
        self.environment = environment
        super.init(frame: .zero)
        wantsLayer = true
        surfaceView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surfaceView)
        NSLayoutConstraint.activate([
            surfaceView.leadingAnchor.constraint(equalTo: leadingAnchor),
            surfaceView.trailingAnchor.constraint(equalTo: trailingAnchor),
            surfaceView.topAnchor.constraint(equalTo: topAnchor),
            surfaceView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        surfaceView.onTitleChange = { [weak self] title in self?.onTitleChange?(title) }
        surfaceView.onProcessExit = { [weak self] exit in self?.onProcessExit?(exit) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !started else { return }
        started = true
        createSurface()
    }

    /// The window asks the views for a key equivalent before the menu bar,
    /// and the surface performs any key Ghostty binds (⌘N is `new_window`).
    /// Not handled here, and not asked of the surface, a yielded key goes on
    /// to the menu bar.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if yieldsKeyEquivalent?(event) == true { return false }
        return super.performKeyEquivalent(with: event)
    }

    /// Moves keyboard focus into the terminal. The pane never takes focus
    /// by itself: the host decides, so creating a pane cannot steal keys
    /// from whatever created it.
    public func focusTerminal() {
        window?.makeFirstResponder(surfaceView)
    }

    /// Frees the engine surface now. It also dies with the view, but a
    /// dismantled pane may linger before deallocation; this ends the tmux
    /// client at once.
    public func teardown() {
        surfaceView.teardownSurface()
    }

    private func createSurface() {
        let controller = GhosttyAppController.shared
        guard let app = controller.app else {
            logger.error("libghostty is not running; no surface for \(self.command, privacy: .public)")
            return
        }
        var config = GhosttyFFI.surfaceConfigNew()
        config.scale_factor = Double(window?.backingScaleFactor ?? (NSScreen.main?.backingScaleFactor ?? 2.0))
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        // ghostty_surface_new copies the strings, so they only need to outlive the call.
        let keys = Array(environment.keys)
        let values = keys.map { environment[$0]! }
        command.withCString { command in
            config.command = command
            keys.withCStrings { keyPointers in
                values.withCStrings { valuePointers in
                    var envVars = zip(keyPointers, valuePointers).map { ghostty_env_var_s(key: $0, value: $1) }
                    envVars.withUnsafeMutableBufferPointer { buffer in
                        config.env_vars = buffer.baseAddress
                        config.env_var_count = buffer.count
                        surfaceView.initializeSurface(app: app, baseConfig: config)
                    }
                }
            }
        }
        if let surfaceController = surfaceView.surfaceController {
            controller.register(surfaceController)
        } else {
            logger.error("surface creation failed for \(self.command, privacy: .public)")
        }
    }
}

extension Array where Element == String {
    /// A C string for every element, all valid for the duration of `body`.
    func withCStrings<T>(_ body: ([UnsafePointer<Int8>?]) -> T) -> T {
        var pointers = [UnsafePointer<Int8>?](repeating: nil, count: count)
        func step(_ index: Int) -> T {
            guard index < count else { return body(pointers) }
            return self[index].withCString { cString in
                pointers[index] = cString
                return step(index + 1)
            }
        }
        return step(0)
    }
}
