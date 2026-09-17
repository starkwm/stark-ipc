import Darwin
import Foundation

public enum LocalSocket {
  public static func address<T>(
    _ path: String,
    body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
  ) throws -> T {
    guard !path.isEmpty, !path.utf8.contains(0) else {
      throw SocketError.message("Invalid socket path.")
    }

    var address = sockaddr_un()
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
      throw SocketError.message("Socket path is too long.")
    }

    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in buffer.copyBytes(from: bytes) }

    return try withUnsafePointer(to: &address) {
      try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
  }

  public static func connect(path: String, serviceName: String = "server") throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SocketError.message(String(cString: strerror(errno))) }

    do {
      let status = try address(path) { Darwin.connect(fd, $0, $1) }
      guard status == 0 else {
        throw SocketError.message(
          "Cannot connect to \(serviceName): \(String(cString: strerror(errno)))"
        )
      }

      var one: Int32 = 1
      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
      _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

      return fd
    } catch {
      close(fd)
      throw error
    }
  }

  public static func send(_ data: Data, to fd: Int32) throws {
    try data.withUnsafeBytes { buffer in
      var offset = 0

      while offset < buffer.count {
        let written = Darwin.send(
          fd,
          buffer.baseAddress!.advanced(by: offset),
          buffer.count - offset,
          0
        )

        if written < 0 && errno == EINTR { continue }
        guard written > 0 else { throw SocketError.message("Socket write failed.") }

        offset += written
      }
    }
  }
}
