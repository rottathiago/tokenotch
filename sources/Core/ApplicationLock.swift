import Darwin
import Foundation

public enum ApplicationLockError: String, Error, LocalizedError {
    case busy = "Another copy of Tokenotch is already running."
    case invalid = "Tokenotch's private launch lock is unavailable or unsafe."
    public var errorDescription: String? { rawValue }
}

public final class ApplicationLock {
    private var descriptor: Int32 = -1
    public init(url: URL) throws {
        let fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ApplicationLockError.invalid }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
              info.st_nlink == 1 else { close(fd); throw ApplicationLockError.invalid }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw ApplicationLockError.busy }
        descriptor = fd
    }
    deinit { if descriptor >= 0 { close(descriptor) } }
}
