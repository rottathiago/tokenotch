import Darwin
import Foundation

public enum PrivateFiles {
    public static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(TokenotchProduct.storageDirectory, isDirectory: true)
    }

    public static func directory(_ url: URL) throws {
        if mkdir(url.path, 0o700) != 0 && errno != EEXIST { throw TokenotchError.unsafePath }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else {
            throw TokenotchError.unsafePath
        }
    }

    public static func read(_ url: URL, limit: Int = 1_048_576) throws -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw TokenotchError.unsafePath }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_size <= limit else { throw TokenotchError.unsafePath }
        var data = Data(count: Int(info.st_size))
        let expected = data.count
        let count = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, expected) }
        guard count == expected else { throw TokenotchError.storage }
        return data
    }

    public static func write(_ data: Data, to url: URL) throws {
        try directory(url.deletingLastPathComponent())
        _ = try read(url, limit: 32 * 1_048_576)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".write-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw TokenotchError.storage }
        defer { close(fd); unlink(temporary.path) }
        let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) }
        guard count == data.count, fsync(fd) == 0, rename(temporary.path, url.path) == 0 else {
            throw TokenotchError.storage
        }
    }
}

private struct Envelope: Codable {
    let registration: String
    let event: ActivityEvent
}

public final class LocalBridge {
    private let root: URL
    private var socketFD: Int32 = -1
    private var lockFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "io.github.rottathiago.tokenotch.bridge")
    private var bucketStart = Date.distantPast
    private var bucketCount = 0
    public var onEvent: ((ActivityEvent) -> Void)?
    public var onFailure: ((TokenotchError) -> Void)?
    public init(root: URL = PrivateFiles.root) { self.root = root }

    public func start() throws {
        guard socketFD < 0 else { return }
        try PrivateFiles.directory(root)
        let lock = open(root.appendingPathComponent("bridge.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw TokenotchError.unsafePath }
        var info = stat()
        guard fstat(lock, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            close(lock)
            throw TokenotchError.bridgeUnavailable
        }
        lockFD = lock
        do {
            let path = root.appendingPathComponent("events.sock").path
            if lstat(path, &info) == 0 {
                guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK else {
                    throw TokenotchError.unsafePath
                }
                guard unlink(path) == 0 else { throw TokenotchError.bridgeUnavailable }
            }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw TokenotchError.bridgeUnavailable }
            socketFD = fd
            var address = try Self.address(path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0,
                  fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw TokenotchError.bridgeUnavailable }
            let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            reader.setEventHandler { [weak self] in self?.receive() }
            source = reader
            reader.resume()
        } catch {
            if socketFD >= 0 { close(socketFD); socketFD = -1 }
            close(lockFD); lockFD = -1
            throw error
        }
    }

    public func stop() {
        queue.sync {
            source?.cancel()
            source = nil
            if socketFD >= 0 {
                close(socketFD); socketFD = -1
                unlink(root.appendingPathComponent("events.sock").path)
            }
            if lockFD >= 0 { close(lockFD); lockFD = -1 }
        }
    }

    private func receive() {
        // Bound both work per wake and accepted event rate, including malformed inputs.
        for _ in 0..<16 {
            let fd = accept(socketFD, nil, nil)
            guard fd >= 0 else { return }
            defer { close(fd) }
            let now = Date()
            if now.timeIntervalSince(bucketStart) >= 1 { bucketStart = now; bucketCount = 0 }
            bucketCount += 1
            guard bucketCount <= 30 else { onFailure?(.invalidEvent); continue }
            do {
                var uid: uid_t = 0
                var gid: gid_t = 0
                guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw TokenotchError.unsafePath }
                let data = try Self.readMessage(fd, limit: 4096, milliseconds: 100)
                let envelope = try JSONDecoder().decode(Envelope.self, from: data)
                guard envelope.event.metricSource == nil else { throw TokenotchError.invalidEvent }
                let registration = root.appendingPathComponent("\(envelope.event.source.rawValue).registration")
                guard let key = try PrivateFiles.read(registration, limit: 128),
                      String(data: key, encoding: .utf8) == envelope.registration else {
                    throw TokenotchError.invalidEvent
                }
                try envelope.event.validate(now: now)
                onEvent?(envelope.event)
            } catch let error as TokenotchError {
                onFailure?(error)
            } catch {
                onFailure?(.invalidEvent)
            }
        }
    }

    public static func send(_ event: ActivityEvent, root: URL = PrivateFiles.root) throws {
        try PrivateFiles.directory(root)
        let registration = root.appendingPathComponent("\(event.source.rawValue).registration")
        guard let key = try PrivateFiles.read(registration, limit: 128),
              let token = String(data: key, encoding: .utf8) else { throw TokenotchError.bridgeUnavailable }
        var data = try JSONEncoder().encode(Envelope(registration: token, event: event))
        data.append(10)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TokenotchError.bridgeUnavailable }
        defer { close(fd) }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw TokenotchError.bridgeUnavailable }
        var address = try Self.address(root.appendingPathComponent("events.sock").path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw TokenotchError.bridgeUnavailable }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw TokenotchError.unsafePath }
        let count = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, data.count, 0) }
        guard count == data.count else { throw TokenotchError.bridgeUnavailable }
    }

    public static func readMessage(_ fd: Int32, limit: Int, milliseconds: Int32,
                                   newlineTerminated: Bool = true) throws -> Data {
        let deadline = ProcessInfo.processInfo.systemUptime + Double(milliseconds) / 1000
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw TokenotchError.invalidEvent }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, Int32(remaining * 1000)) > 0 else { throw TokenotchError.invalidEvent }
            let count = Darwin.read(fd, &buffer, min(buffer.count, limit + 1 - result.count))
            guard count >= 0 else { throw TokenotchError.invalidEvent }
            if count == 0 { return result }
            result.append(contentsOf: buffer.prefix(count))
            guard result.count <= limit else { throw TokenotchError.invalidEvent }
            if newlineTerminated, let index = result.firstIndex(of: 10) {
                guard index == result.count - 1 else { throw TokenotchError.invalidEvent }
                return result.prefix(index)
            }
        }
    }

    private static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw TokenotchError.unsafePath }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }
}
