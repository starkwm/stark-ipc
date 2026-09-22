import Darwin
import Foundation

/// A synchronous connection. Confine each instance to one caller.
public final class SocketClient {
  private let fd: Int32
  private var pending = Data()

  public init(path: String, serviceName: String = "server", streaming: Bool = false) throws {
    fd = try LocalSocket.connect(path: path, serviceName: serviceName)

    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    if !streaming {
      setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }
  }

  deinit { close(fd) }

  public func send<Request: Encodable>(_ request: Request) throws {
    var data = try JSONEncoder().encode(request)
    data.append(10)

    try LocalSocket.send(data, to: fd)
  }

  public func receive<Response: Decodable>(_ type: Response.Type) throws -> Response {
    try JSONDecoder().decode(type, from: receiveLine())
  }

  /// Returns one JSON line without its newline, preserving the original bytes.
  public func receiveLine() throws -> Data {
    var buffer = [UInt8](repeating: 0, count: 8192)

    while true {
      if let newline = pending.firstIndex(of: 10) {
        let line = Data(pending.prefix(upTo: newline))
        pending.removeSubrange(...newline)

        return line
      }

      let count = recv(fd, &buffer, buffer.count, 0)

      if count < 0 && errno == EINTR { continue }
      guard count > 0 else { throw SocketError.message("Connection closed or timed out.") }

      pending.append(contentsOf: buffer.prefix(count))

      guard pending.count <= 1_048_576 else { throw SocketError.message("Response too large.") }
    }
  }
}
