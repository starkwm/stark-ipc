import Darwin
import Foundation

/// All mutable connection state is confined to queue; handlers cross to the main actor explicitly.
public final class SocketServer<Request: Decodable & Sendable, Response: Encodable & Sendable>:
  @unchecked Sendable
{
  private struct Connection {
    let id = UUID()
    let source: any DispatchSourceRead
    var data = Data()
    var subscribed = false
    var handling = false
  }

  private let serviceName: String
  private let errorResponse: @Sendable (any Error) -> Response
  private let path: String
  private let handler: @Sendable (Request) async -> SocketReply<Response>

  private let queue = DispatchQueue(label: "StarkIPC.control")

  private let queueKey = DispatchSpecificKey<Bool>()

  private var listener: (any DispatchSourceRead)?
  private var connections: [Int32: Connection] = [:]
  private var lock: Int32 = -1
  private var socketIdentity: (dev_t, ino_t)?

  public init(
    path: String,
    serviceName: String = "server",
    errorResponse: @escaping @Sendable (any Error) -> Response,
    handler: @escaping @Sendable (Request) async -> SocketReply<Response>
  ) {
    self.path = path
    self.serviceName = serviceName
    self.errorResponse = errorResponse
    self.handler = handler

    queue.setSpecific(key: queueKey, value: true)
  }

  deinit { stop() }

  public func start() throws {
    try queue.sync {
      guard listener == nil else { return }

      try LocalSocket.address(path) { _, _ in }

      let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

      lock = open(path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
      guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
        if lock >= 0 {
          close(lock)
          lock = -1
        }

        throw SocketError.message("Another \(serviceName) instance owns the control socket.")
      }

      do {
        var info = stat()
        if lstat(path, &info) == 0 {
          guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK else {
            throw SocketError.message(
              "Refusing to replace a non-socket or another user's socket."
            )
          }

          unlink(path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.message("Cannot create control socket.") }

        let status: Int32
        do { status = try LocalSocket.address(path) { bind(fd, $0, $1) } } catch {
          close(fd)
          throw error
        }

        if status == 0 {
          var bound = stat()
          if lstat(path, &bound) == 0, bound.st_mode & S_IFMT == S_IFSOCK {
            socketIdentity = (bound.st_dev, bound.st_ino)
          }
        }

        guard status == 0, socketIdentity != nil, chmod(path, 0o600) == 0, listen(fd, 16) == 0
        else {
          close(fd)
          throw SocketError.message("Cannot bind control socket.")
        }

        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClients(fd) }
        source.setCancelHandler { close(fd) }
        listener = source
        source.resume()
      } catch {
        removeOwnedSocket()
        close(lock)
        lock = -1

        throw error
      }
    }
  }

  public func stop() {
    if DispatchQueue.getSpecific(key: queueKey) == true {
      stopOnQueue()
    } else {
      queue.sync { stopOnQueue() }
    }
  }

  public func publish(_ response: Response) {
    queue.async { [weak self] in
      guard let self else { return }

      for fd in self.connections.keys.filter({ self.connections[$0]?.subscribed == true }) {
        self.respond(response, to: fd, closeAfter: false)
      }
    }
  }

  private func stopOnQueue() {
    guard listener != nil else { return }

    listener?.cancel()
    listener = nil

    for fd in Array(connections.keys) { disconnect(fd) }

    removeOwnedSocket()

    if lock >= 0 {
      close(lock)
      lock = -1
    }
  }

  private func removeOwnedSocket() {
    guard let identity = socketIdentity else { return }

    var info = stat()
    if lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK,
      info.st_dev == identity.0, info.st_ino == identity.1
    {
      unlink(path)
    }

    socketIdentity = nil
  }

  private func acceptClients(_ fd: Int32) {
    while true {
      let client = accept(fd, nil, nil)
      guard client >= 0 else { return }

      var uid: uid_t = 0
      var gid: gid_t = 0
      guard connections.count < 32, getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
        close(client)
        continue
      }

      _ = fcntl(client, F_SETFL, O_NONBLOCK)
      _ = fcntl(client, F_SETFD, FD_CLOEXEC)

      var one: Int32 = 1
      setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

      let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
      source.setEventHandler { [weak self] in self?.readClient(client) }
      source.setCancelHandler { close(client) }

      let connection = Connection(source: source)
      let id = connection.id
      connections[client] = connection
      source.resume()

      queue.asyncAfter(deadline: .now() + 5) { [weak self] in
        guard self?.connections[client]?.id == id, self?.connections[client]?.subscribed == false
        else { return }

        self?.disconnect(client)
      }
    }
  }

  private func readClient(_ fd: Int32) {
    var buffer = [UInt8](repeating: 0, count: 4096)
    let count = recv(fd, &buffer, buffer.count, 0)
    guard count > 0 else {
      if count == 0 || (errno != EAGAIN && errno != EINTR) { disconnect(fd) }
      return
    }

    guard connections[fd]?.handling == false else {
      disconnect(fd)
      return
    }

    connections[fd]?.data.append(contentsOf: buffer.prefix(count))

    guard let connection = connections[fd] else { return }
    guard connection.data.count <= 131_072 else {
      disconnect(fd)
      return
    }

    guard let newline = connection.data.firstIndex(of: 10) else { return }

    let id = connection.id
    connections[fd]?.handling = true

    do {
      let request = try JSONDecoder().decode(
        Request.self,
        from: connection.data.prefix(upTo: newline)
      )

      Task { [weak self, handler] in
        let reply = await handler(request)

        self?.queue.async { [weak self] in
          guard let self else { return }
          defer { reply.onComplete() }

          guard self.connections[fd]?.id == id else { return }

          self.connections[fd]?.subscribed = reply.keepOpen
          self.respond(reply.response, to: fd, closeAfter: !reply.keepOpen)
        }
      }
    } catch { respond(errorResponse(error), to: fd) }
  }

  private func respond(_ response: Response, to fd: Int32, closeAfter: Bool = true) {
    do {
      var data = try JSONEncoder().encode(response)
      data.append(10)

      // Disconnect slow clients rather than blocking the runtime or growing buffers.
      try LocalSocket.send(data, to: fd)
      if closeAfter { disconnect(fd) }
    } catch { disconnect(fd) }
  }

  private func disconnect(_ fd: Int32) { connections.removeValue(forKey: fd)?.source.cancel() }
}
