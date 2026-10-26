@preconcurrency import AppKit
import GhosttyKit
import os

private let logger = Logger(subsystem: "com.bosun.Bosun", category: "TerminalPane")

/// One embedded terminal running one command. The surface is created when
/// the view first lands in a window (libghostty needs the window's backing
/// scale), and lives until `close()` or deallocation.
@MainActor
public final class TerminalPane: NSView {
    public struct Launch: Sendable {
        public var command: String
        public var workingDirectory: String?
        public var environment: [String: String]

        public init(command: String, workingDirectory: String? = nil, environment: [String: String] = [:]) {
            self.command = command
            self.workingDirectory = workingDirectory
            self.environment = environment
        }
    }

    public var onTitleChange: ((String) -> Void)?
    public var onProcessExit: (() -> Void)?

    public private(set) var title = ""

    private let launch: Launch
    private let surfaceView = SurfaceView(frame: .zero)
    private var started = false

    public init(launch: Launch) {
        self.launch = launch
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
        surfaceView.onTitleChange = { [weak self] value in
            self?.title = value
            self?.onTitleChange?(value)
        }
        surfaceView.onProcessExit = { [weak self] in
            self?.onProcessExit?()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public static var engineError: String? {
        if case .error(let message) = GhosttyAppController.shared.readiness { return message }
        return nil
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !started else { return }
        started = true
        createSurface()
    }

    /// Moves keyboard focus into the terminal.
    public func focusTerminal() {
        window?.makeFirstResponder(surfaceView)
    }

    public func close() {
        surfaceView.surfaceController?.requestClose()
    }

    private func createSurface() {
        let controller = GhosttyAppController.shared
        guard let app = controller.app else {
            logger.error("no ghostty app: \(String(describing: controller.readiness), privacy: .public)")
            return
        }
        var config = GhosttyFFI.surfaceConfigNew()
        config.scale_factor = Double(window?.backingScaleFactor ?? (NSScreen.main?.backingScaleFactor ?? 2.0))
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        // Strings must outlive ghostty_surface_new only; it copies them.
        let keys = Array(launch.environment.keys)
        let values = keys.map { launch.environment[$0]! }
        launch.command.withCString { command in
            config.command = command
            withOptionalCString(launch.workingDirectory) { cwd in
                config.working_directory = cwd
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
        }
        if let surfaceController = surfaceView.surfaceController {
            controller.register(surfaceController)
        } else {
            logger.error("surface creation failed for \(self.launch.command, privacy: .public)")
        }
    }
}

private func withOptionalCString<T>(_ value: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
    guard let value else { return body(nil) }
    return value.withCString { body($0) }
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
