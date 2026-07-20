import Foundation
import Darwin

public enum ProjectLockError: Error, Equatable {
    case alreadyLocked(URL)
    case openFailed(URL, errno: Int32)
    case lockFailed(URL, errno: Int32)
}

public final class ProjectLock {
    public let root: URL
    public let lockFile: URL
    private var fd: CInt = -1

    public init(root: URL) {
        self.root = root
        self.lockFile = root.appendingPathComponent(".continuum-revived", isDirectory: true)
            .appendingPathComponent("lock", isDirectory: false)
    }

    deinit {
        release()
    }

    public func acquire() throws {
        guard fd == -1 else { return }
        let lockDir = lockFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: lockDir, withIntermediateDirectories: true)
        // EINTR retry is mandatory here: the boot-restore fan-out spawns
        // child processes (git/tmux/sqlite) concurrently with this acquire,
        // and a SIGCHLD landing mid-syscall interrupts it. Without the retry
        // the app dies at launch with openFailed(errno: 4) — seen in the
        // wild 2026-07-20.
        var opened: CInt = -1
        repeat {
            opened = Darwin.open(lockFile.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        } while opened < 0 && errno == EINTR
        guard opened >= 0 else {
            throw ProjectLockError.openFailed(lockFile, errno: errno)
        }
        if fcntl(opened, F_SETFD, FD_CLOEXEC) != 0 {
            let captured = errno
            Darwin.close(opened)
            throw ProjectLockError.openFailed(lockFile, errno: captured)
        }
        var flocked: CInt = -1
        repeat {
            flocked = flock(opened, LOCK_EX | LOCK_NB)
        } while flocked != 0 && errno == EINTR
        if flocked != 0 {
            let captured = errno
            Darwin.close(opened)
            if captured == EWOULDBLOCK || captured == EAGAIN {
                throw ProjectLockError.alreadyLocked(lockFile)
            }
            throw ProjectLockError.lockFailed(lockFile, errno: captured)
        }
        fd = opened
    }

    public func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        Darwin.close(fd)
        fd = -1
    }
}
