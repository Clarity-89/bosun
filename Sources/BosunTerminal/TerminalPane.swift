@preconcurrency import AppKit
import GhosttyKit
import os

private let logger = Logger(subsystem: "com.bosun.Bosun", category: "TerminalPane")

/// One embedded terminal running one command. The surface is created when
/// the view first lands in a window (libghostty needs the window's backing
/// scale) and freed with the view.
@MainActor
public final class TerminalPane: NSView {
    public var onTitleChange: ((String) -> Void)?
    /// The command ended or the engine closed the surface; the view is done.
    public var onProcessExit: (() -> Void)?

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
        surfaceView.onProcessExit = { [weak self] in self?.onProcessExit?() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !started else { return }
        started = true
        createSurface()
    }

    /// Moves keyboard focus into the terminal. Never called automatically:
    /// a pane created by arrow-key navigation in the list must not steal
    /// the keys the user is navigating with.
    public func focusTerminal() {
        window?.makeFirstResponder(surfaceView)
    }

    /// Frees the engine surface while this view still exists. Called by the
    /// host when SwiftUI dismantles the pane; relying on deinit ordering
    /// instead let engine callbacks reach a deallocated view.
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

        // Before surface_new: INITIAL_SIZE and CELL_SIZE arrive synchronously
        // from inside it and are dropped for an unregistered view.
        GhosttyAppController.registerLive(surfaceView)

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
            GhosttyAppController.unregisterLive(surfaceView)
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
