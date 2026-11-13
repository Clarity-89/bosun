import CSentry
import Darwin
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

    /// Whether this process receives its own bad-access faults, as it does
    /// while Breakpad runs. Breakpad takes every fault type on one port, so
    /// one type answers for all, and every process this one starts inherits
    /// that port.
    static func takesFaults() -> Bool {
        let task = mach_task_self_
        var mask: exception_mask_t = 0
        var port = mach_port_t(MACH_PORT_NULL)
        var behavior: exception_behavior_t = 0
        var flavor: thread_state_flavor_t = 0
        // One exception type has one port, so one entry is room enough.
        var count: mach_msg_type_number_t = 1
        guard task_get_exception_ports(task, exception_mask_t(EXC_MASK_BAD_ACCESS), &mask, &count, &port, &behavior, &flavor) == KERN_SUCCESS,
              // ~0 is MACH_PORT_DEAD, which Swift does not import: a port
              // whose receiver is gone, and no name in this task.
              port != MACH_PORT_NULL, port != ~0
        else { return false }
        // The read added a send right to the port; this gives it back.
        defer { mach_port_deallocate(task, port) }
        var refs: mach_port_urefs_t = 0
        return mach_port_get_refs(task, port, MACH_PORT_RIGHT_RECEIVE, &refs) == KERN_SUCCESS && refs > 0
    }
}
