import CSentry
import Darwin
import GhosttyKit
import os

private let logger = Logger(subsystem: "com.bosun.Bosun", category: "GhosttyInit")

/// `ghostty_init`, once per process, with libghostty's crash reporter shut
/// down again.
///
/// ghostty_init starts Sentry on a thread of its own, and Sentry's Breakpad
/// backend takes the task's exception ports for hardware faults. Every
/// process Bosun starts inherits those ports, and so does all they start:
/// the tmux server agent-deck launches and every agent under it. Breakpad
/// cannot pass another process's fault on, as the release build strips its
/// `catch_exception_raise`, so a fault in any agent ended Bosun with exit
/// status 1; Bosun's own crashes ended the same way, with no crash report.
enum GhosttyInit {
    /// Runs it on the first call; later calls return that call's result.
    static func run() -> Bool { result }

    private static let result: Bool = {
        guard GhosttyFFI.initialize() else { return false }
        closeCrashReporter()
        return true
    }()

    /// Sentry is up within a millisecond of ghostty_init; the second covers
    /// a machine busy logging in.
    private static func closeCrashReporter() {
        let deadline = ContinuousClock.now + .seconds(1)
        while !takesFaults() {
            guard ContinuousClock.now < deadline else {
                logger.warning("libghostty's crash reporter took no exception ports within a second")
                break
            }
            usleep(1_000)
        }
        // sentry_init holds the lock sentry_close takes until it is done, so
        // this waits out the rest of it; closing gives back the exception
        // ports and the SIGABRT handler Breakpad replaced.
        _ = sentry_close()
    }

    /// Whether this process receives hardware faults itself, as Breakpad
    /// does: its own, and those of every process it starts.
    static func takesFaults() -> Bool {
        let task = mach_task_self_
        let capacity = Int(EXC_TYPES_COUNT)
        var masks = [exception_mask_t](repeating: 0, count: capacity)
        var ports = [mach_port_t](repeating: mach_port_t(MACH_PORT_NULL), count: capacity)
        var behaviors = [exception_behavior_t](repeating: 0, count: capacity)
        var flavors = [thread_state_flavor_t](repeating: 0, count: capacity)
        var count = mach_msg_type_number_t(capacity)
        let faults = exception_mask_t(EXC_MASK_BAD_ACCESS | EXC_MASK_BAD_INSTRUCTION | EXC_MASK_ARITHMETIC | EXC_MASK_BREAKPOINT)
        guard task_get_exception_ports(task, faults, &masks, &count, &ports, &behaviors, &flavors) == KERN_SUCCESS else {
            return false
        }
        var receives = false
        // ~0 is MACH_PORT_DEAD, which Swift does not import: a port whose
        // receiver is gone, and no name in this task.
        for port in ports.prefix(Int(count)) where port != MACH_PORT_NULL && port != ~0 {
            var refs: mach_port_urefs_t = 0
            if mach_port_get_refs(task, port, MACH_PORT_RIGHT_RECEIVE, &refs) == KERN_SUCCESS, refs > 0 {
                receives = true
            }
            // The read added a send right to each port; this gives it back.
            mach_port_deallocate(task, port)
        }
        return receives
    }
}
