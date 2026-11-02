import Foundation

/// The wire format between the `planet` CLI and the app: one JSON object per connection
/// each way, over a Unix socket only the current user can open.
public struct IPCRequest: Codable, Sendable {
    public var args: [String]
    public init(args: [String]) { self.args = args }
}

public struct IPCResponse: Codable, Sendable {
    public var ok: Bool
    public var output: String
    public init(ok: Bool, output: String) {
        self.ok = ok
        self.output = output
    }
}

public enum IPC {
    /// The socket lives with the app's other files. Its path stays well under the
    /// 104-byte limit macOS puts on Unix socket paths.
    public static var socketPath: String {
        if let override = ProcessInfo.processInfo.environment["PLANETS_SOCKET"] { return override }
        return supportDirectory.appendingPathComponent("planets.sock").path
    }

    /// Sends one request to a socket and reads the one response, or nil when nobody's there.
    /// With a timeout, a process that's alive but stuck can't hold the caller past it.
    public static func request(_ args: [String], socket path: String = socketPath, timeout: Int? = nil) -> IPCResponse? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        if let timeout {
            var limit = timeval(tv_sec: timeout, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8.prefix(buffer.count - 1))
            buffer[min(path.utf8.count, buffer.count - 1)] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0, var request = try? JSONEncoder().encode(IPCRequest(args: args)) else { return nil }
        request.append(0x0A)
        _ = request.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return try? JSONDecoder().decode(IPCResponse.self, from: data.prefix { $0 != 0x0A })
    }

    public static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["PLANETS_SUPPORT"] { return URL(fileURLWithPath: override, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Planets", isDirectory: true)
    }

    public static var configURL: URL {
        if let override = ProcessInfo.processInfo.environment["PLANETS_CONFIG"] { return URL(fileURLWithPath: override) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/planets/planets.toml")
    }
}
