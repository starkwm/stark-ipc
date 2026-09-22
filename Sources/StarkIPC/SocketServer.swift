import Darwin
import Foundation

/// The serial queue owns connection state. Request handlers run in separate tasks.
public final class SocketServer<Request: Decodable & Sendable, Response: Encodable & Sendable>:
  @unchecked Sendable
{
  private struct Write {
    let data: Data
    let onComplete: (@Sendable () -> Void)?
    var offset = 0
  }

  private struct Connection {
    let id = UUID()
    let source: any DispatchSourceRead
    var data = Data()
    var subscribed = false
    var handling = false
    var writes: [Write] = []
    var writer: (any DispatchSourceWrite)?
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
        removeSocket()
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

      for (fd, connection) in self.connections where connection.subscribed {
        self.respond(response, to: fd)
      }
    }
  }

  private func stopOnQueue() {
    guard listener != nil else { return }

    listener?.cancel()
    listener = nil

    for fd in Array(connections.keys) { disconnect(fd) }

    removeSocket()

    if lock >= 0 {
      close(lock)
      lock = -1
    }
  }

  private func removeSocket() {
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

          guard self.connections[fd]?.id == id else {
            reply.onComplete()
            return
          }

          self.connections[fd]?.subscribed = reply.keepOpen
          self.respond(reply.response, to: fd, onComplete: reply.onComplete)
        }
      }
    } catch { respond(errorResponse(error), to: fd) }
  }

  private func respond(
    _ response: Response,
    to fd: Int32,
    onComplete: (@Sendable () -> Void)? = nil
  ) {
    do {
      var data = try JSONEncoder().encode(response)
      data.append(10)

      let writes = connections[fd]?.writes ?? []
      let pendingBytes = writes.reduce(0) { $0 + $1.data.count - $1.offset }

      guard writes.count < 256, data.count <= 1_048_576 - pendingBytes else {
        throw SocketError.message("Response buffer is full.")
      }

      connections[fd]?.writes.append(Write(data: data, onComplete: onComplete))
      writeClient(fd)
    } catch {
      disconnect(fd)
      onComplete?()
    }
  }

  private func writeClient(_ fd: Int32) {
    while let write = connections[fd]?.writes.first {
      let count = write.data.withUnsafeBytes { buffer in
        Darwin.send(
          fd,
          buffer.baseAddress!.advanced(by: write.offset),
          buffer.count - write.offset,
          0
        )
      }

      if count < 0 && errno == EINTR { continue }

      if count < 0 && errno == EAGAIN {
        waitToWrite(fd)
        return
      }

      guard count > 0 else {
        disconnect(fd)
        return
      }

      connections[fd]?.writes[0].offset += count

      guard write.offset + count == write.data.count else { continue }

      connections[fd]?.writes.removeFirst()

      if connections[fd]?.subscribed == false { disconnect(fd) }

      write.onComplete?()
    }

    connections[fd]?.writer?.cancel()
    connections[fd]?.writer = nil
  }

  private func waitToWrite(_ fd: Int32) {
    guard let connection = connections[fd], connection.writer == nil else { return }

    // Give the write source its own descriptor so either source can cancel safely.
    let descriptor = dup(fd)

    guard descriptor >= 0 else {
      disconnect(fd)
      return
    }

    _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)

    let id = connection.id
    let writer = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
    writer.setEventHandler { [weak self] in
      guard self?.connections[fd]?.id == id else { return }

      self?.writeClient(fd)
    }
    writer.setCancelHandler { close(descriptor) }
    connections[fd]?.writer = writer
    writer.resume()

    queue.asyncAfter(deadline: .now() + 5) { [weak self] in
      guard self?.connections[fd]?.writer === writer else { return }

      self?.disconnect(fd)
    }
  }

  private func disconnect(_ fd: Int32) {
    guard let connection = connections.removeValue(forKey: fd) else { return }

    connection.writer?.cancel()
    connection.source.cancel()

    for write in connection.writes { write.onComplete?() }
  }
}
