import Darwin
import Foundation

/// Which of the shells a process spawned run a command, read from the
/// process table. libghostty holds the shells' ptys, so Bosun cannot ask a
/// tty for its foreground job; the kernel's view of each shell says the same.
public enum ForegroundJobs {
    /// The working directory of every shell two levels under `root`
    /// (libghostty runs each command under `login`) whose tty's foreground
    /// is another live process group: a command, not the prompt. Symlinks
    /// resolved, as the kernel reports them.
    public static func busyShellDirectories(under root: pid_t) -> [String] {
        var directories: [String] = []
        for login in children(of: root) {
            for shell in children(of: login) {
                guard let info = bsdInfo(shell), info.e_tdev != UInt32.max,
                      info.e_tpgid != info.pbi_pgid, bsdInfo(pid_t(info.e_tpgid)) != nil,
                      let directory = workingDirectory(of: shell)
                else { continue }
                directories.append(directory)
            }
        }
        return directories
    }

    private static func children(of pid: pid_t) -> [pid_t] {
        let bound = proc_listchildpids(pid, nil, 0)
        guard bound > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bound))
        let count = proc_listchildpids(pid, &pids, bound * Int32(MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(count, 0))))
    }

    /// Nil for a process of another user, as `login` is root's.
    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    private static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }
}
