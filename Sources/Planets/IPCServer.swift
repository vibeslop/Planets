import Foundation
import PlanetsCore

/// Serves the `planet` CLI over a Unix socket. Connections are read off the main thread;
/// only the command itself runs on the main thread, where the window manager lives.
final class IPCServer: @unchecked Sendable {
    typealias Handler = @MainActor ([String]) -> IPCResponse

    private let handler: Handler
    private let queue = DispatchQueue(label: "planets.ipc", qos: .userInitiated)
    private var listenSocket: Int32 = -1
    private var source: DispatchSourceRead?

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func start() throws {
        let path = IPC.socketPath
        try FileManager.default.createDirectory(at: IPC.supportDirectory, withIntermediateDirectories: true)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { close(fd); throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            let error = POSIXError(.init(rawValue: errno) ?? .EIO)
            close(fd)
            throw error
        }
        // Only this user may talk to the window manager.
        chmod(path, 0o600)
        listenSocket = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept() }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        if listenSocket >= 0 { close(listenSocket) }
        unlink(IPC.socketPath)
    }

    private func accept() {
        let client = Darwin.accept(listenSocket, nil, nil)
        guard client >= 0 else { return }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !data.contains(0x0A) && data.count < 1 << 20 {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        guard let request = try? JSONDecoder().decode(IPCRequest.self, from: data.prefix { $0 != 0x0A }) else {
            respond(client, IPCResponse(ok: false, output: "malformed request"))
            return
        }
        let handler = self.handler
        DispatchQueue.main.async { [self] in
            let response = MainActor.assumeIsolated { handler(request.args) }
            queue.async { self.respond(client, response) }
        }
    }

    private func respond(_ client: Int32, _ response: IPCResponse) {
        if var payload = try? JSONEncoder().encode(response) {
            payload.append(0x0A)
            payload.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = write(client, buffer.baseAddress! + offset, buffer.count - offset)
                    guard written > 0 else { break }
                    offset += written
                }
            }
        }
        close(client)
    }
}
