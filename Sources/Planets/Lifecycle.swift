import Foundation
import PlanetsCore

/// What keeps Planets one process, and brings it back when it dies holding windows.
///
/// Planets parks windows of hidden workspaces in a screen corner and puts them back when it
/// quits. A crash skips that, so a small watcher (`planet`, in the bundle's Helpers) waits on
/// a pipe Planets holds and opens Planets again, which finds the windows where its saved
/// state says they belong. The pipe says what happened:
///
///   "c"  crashed: open Planets again, unless it died within 15 seconds of starting, which
///        would only crash again
///   "r"  asked to start over, as after Accessibility comes back or an update: open it again
///   end of file with no byte: it quit, or was killed on purpose; nothing to do
enum Lifecycle {
    /// Held for the life of the process; the lock goes with it, however it ends.
    nonisolated(unsafe) private static var lockFile: Int32 = -1

    /// Takes the lock only one Planets can hold. A second copy would delete the first's
    /// socket and tile the same windows against it.
    static func claimSingleInstance(in directory: URL = IPC.supportDirectory) -> Bool {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("planets.lock").path
        // Close-on-exec, so a command run from a key doesn't hold the lock after Planets quits.
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return true }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        lockFile = fd
        return true
    }

    /// Starts the watcher. None for a build run outside its bundle, which has no watcher to
    /// start, or for a test run with folders of its own (PLANETS_SUPPORT), which a relaunch
    /// through `open` would lose: it would start a second, real Planets instead.
    static func watch() {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/planet").path
        guard Bundle.main.bundleURL.pathExtension == "app", FileManager.default.isExecutableFile(atPath: helper),
              ProcessInfo.processInfo.environment["PLANETS_SUPPORT"] == nil else { return }
        var ends: [Int32] = [0, 0]
        guard pipe(&ends) == 0 else { return }
        let (readEnd, writeEnd) = (ends[0], ends[1])
        // Only Planets holds the write end, so the watcher sees the end of the file the moment
        // Planets is gone. A command run from a key inheriting it would hold that off.
        _ = fcntl(writeEnd, F_SETFD, FD_CLOEXEC)
        // A watcher already gone (killed with Planets's terminal) mustn't take Planets with it.
        _ = fcntl(writeEnd, F_SETNOSIGPIPE, 1)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, readEnd, 0)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        // Nothing else open is passed on, and a session of its own keeps ⌃C in the terminal
        // that started Planets from reaching the watcher.
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

    /// Whether a watcher is there to open Planets again.
    static var canRelaunch: Bool { pipeEnd >= 0 }

    /// Opens Planets again from the watcher and exits without putting windows back: the new
    /// copy finds them parked and keeps them so, where putting them back would flash every
    /// hidden workspace on screen.
    static func relaunch() -> Never {
        tell("r")
        exit(0)
    }

    nonisolated(unsafe) fileprivate static var pipeEnd: Int32 = -1

    fileprivate static func tell(_ byte: Character) {
        guard pipeEnd >= 0, var value = byte.asciiValue else { return }
        _ = write(pipeEnd, &value, 1)
    }
}

/// Runs in the dying process, so only calls safe in a signal handler: one write, then the
/// signal again with its default action, which ends the process and writes the crash report.
private func crashed(_ sig: Int32) {
    var value = UInt8(ascii: "c")
    _ = write(Lifecycle.pipeEnd, &value, 1)
    signal(sig, SIG_DFL)
    raise(sig)
}
