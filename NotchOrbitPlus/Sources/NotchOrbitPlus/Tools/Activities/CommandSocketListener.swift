import Foundation
import Darwin
import NotchCore

/// This receiver accepts activity metadata only. It has no command execution path.
final class CommandSocketListener: @unchecked Sendable {
    let socketURL: URL
    private let lock = NSLock()
    private var source: (any DispatchSourceRead)?
    private let queue = DispatchQueue(label: "NotchOrbitPlus.CommandActivitySocket", qos: .utility)
    private let teardown = DispatchGroup()
    static var directory: URL { URL(fileURLWithPath: "/tmp/notchorbitplus-\(getuid())", isDirectory: true) }
    static var endpoint: URL { directory.appendingPathComponent("activities.sock") }
    init(receive: @escaping @Sendable (Data) -> Void, failure: @escaping @Sendable (String) -> Void) throws {
        socketURL = Self.endpoint
        let root = Self.directory
        if !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try Self.checkNode(root, kind: UInt32(S_IFDIR), permissions: 0o700)
        let pidFile = root.appendingPathComponent("listener.pid")
        if FileManager.default.fileExists(atPath: pidFile.path) {
            try Self.checkNode(pidFile, kind: UInt32(S_IFREG), permissions: 0o600)
            let attributes = try FileManager.default.attributesOfItem(atPath: pidFile.path)
            guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 32 else { throw CommandActivityError.invalid("The activity listener lock exceeds its size limit.") }
            let bytes = try Data(contentsOf: pidFile, options: .mappedIfSafe)
            guard bytes.count <= 32, let text = String(data: bytes, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else {
                throw CommandActivityError.invalid("The activity listener lock is invalid. Remove only listener.pid in \(root.path) after quitting the app.")
            }
            guard kill(pid, 0) != 0, errno == ESRCH else { throw CommandActivityError.invalid("Another command activity listener is already running.") }
            if FileManager.default.fileExists(atPath: socketURL.path) { try Self.checkNode(socketURL, kind: UInt32(S_IFSOCK), permissions: 0o600); try FileManager.default.removeItem(at: socketURL) }
            try FileManager.default.removeItem(at: pidFile)
        } else if FileManager.default.fileExists(atPath: socketURL.path) {
            throw CommandActivityError.invalid("An unowned listener session already occupies the activity socket. Quit other instances before removing that socket.")
        }
        let pidDescriptor = open(pidFile.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard pidDescriptor >= 0 else { throw Self.failure("Could not reserve the command listener") }
        let pidHandle = FileHandle(fileDescriptor: pidDescriptor, closeOnDealloc: true)
        do { try pidHandle.write(contentsOf: Data("\(getpid())".utf8)); try pidHandle.close() }
        catch { try? pidHandle.close(); try? FileManager.default.removeItem(at: pidFile); throw error }
        let descriptor = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { try? FileManager.default.removeItem(at: pidFile); throw Self.failure("Could not create the local activity socket") }
        do {
            var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let path = Array(socketURL.path.utf8) + [0]
            guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw CommandActivityError.invalid("The local socket path is too long.") }
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in buffer.copyBytes(from: path) }
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0, chmod(socketURL.path, 0o600) == 0,
                  fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { throw Self.failure("Could not secure the local activity socket") }
            try Self.checkNode(socketURL, kind: UInt32(S_IFSOCK), permissions: 0o600)
            let read = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            let endpoint = socketURL
            let teardown = self.teardown
            read.setEventHandler {
                var buffer = [UInt8](repeating: 0, count: 4_097)
                for _ in 0..<64 {
                    let count = buffer.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress, $0.count, 0) }
                    if count < 0 {
                        if errno != EAGAIN && errno != EWOULDBLOCK { failure("The command activity socket could not read a message.") }
                        return
                    }
                    if count == 0 { continue }
                    guard count <= 4_096 else { failure("A command activity message exceeded 4,096 bytes and was rejected."); continue }
                    receive(Data(buffer.prefix(count)))
                }
            }
            read.setCancelHandler {
                close(descriptor)
                try? FileManager.default.removeItem(at: endpoint)
                try? FileManager.default.removeItem(at: pidFile)
                teardown.leave()
            }
            teardown.enter()
            source = read; read.resume()
        } catch {
            close(descriptor); try? FileManager.default.removeItem(at: socketURL); try? FileManager.default.removeItem(at: pidFile); throw error
        }
    }
    func stop() {
        lock.lock(); let current = source; source = nil; lock.unlock()
        current?.cancel()
        // The receiver queue never waits for the main actor. Drain its bounded
        // callback before allowing a reopened panel to bind this same endpoint.
        teardown.wait()
    }
    deinit { stop() }
    private static func checkNode(_ url: URL, kind: UInt32, permissions: UInt32) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == getuid(),
              UInt32(info.st_mode) & UInt32(S_IFMT) == kind, UInt32(info.st_mode) & 0o777 == permissions else {
            throw CommandActivityError.invalid("The command listener needs an owned \(permissions == 0o700 ? "0700 directory" : "0600 file/socket") without symbolic links.")
        }
    }
    private static func failure(_ text: String) -> CommandActivityError { .invalid("\(text): \(String(cString: strerror(errno))).") }
}
