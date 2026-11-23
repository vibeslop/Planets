import Foundation
import PlanetsCore

enum Lifecycle {
    // SAFETY: Written once at startup and kept open until process exit.
    nonisolated(unsafe) private static var lockFile: Int32 = -1

    static func claimSingleInstance(in directory: URL = IPC.supportDirectory) -> Bool {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("planets.lock").path
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return true }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        lockFile = fd
        return true
    }

    static func watch() {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/planet").path
        guard Bundle.main.bundleURL.pathExtension == "app", FileManager.default.isExecutableFile(atPath: helper),
              ProcessInfo.processInfo.environment["PLANETS_SUPPORT"] == nil else { return }
        var ends: [Int32] = [0, 0]
        guard pipe(&ends) == 0 else { return }
        let (readEnd, writeEnd) = (ends[0], ends[1])
        _ = fcntl(writeEnd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeEnd, F_SETNOSIGPIPE, 1)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, readEnd, 0)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSID))
        let arguments = [helper, "_watch", Bundle.main.bundleURL.path]
        var argv = arguments.map { strdup($0) } + [nil]
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, helper, &actions, &attributes, &argv, environ)
        for pointer in argv { free(pointer) }
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attributes)
        close(readEnd)
        guard spawned == 0 else {
            close(writeEnd)
            return
        }
        pipeEnd = writeEnd
        for sig in [SIGTRAP, SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE] {
            signal(sig, crashed)
        }
    }

    static var canRelaunch: Bool { pipeEnd >= 0 }

    static func relaunch() -> Never {
        tell("r")
        exit(0)
    }

    // SAFETY: Written once before signal handlers install; read-only in crashed().
    nonisolated(unsafe) fileprivate static var pipeEnd: Int32 = -1

    fileprivate static func tell(_ byte: Character) {
        guard pipeEnd >= 0, var value = byte.asciiValue else { return }
        _ = write(pipeEnd, &value, 1)
    }
}

// SAFETY: Async-signal-safe only (single write, reset signal, re-raise).
private func crashed(_ sig: Int32) {
    var value = UInt8(ascii: "c")
    _ = write(Lifecycle.pipeEnd, &value, 1)
    signal(sig, SIG_DFL)
    raise(sig)
}
