# LocalSocket and SocketError

[Documentation index](../index.md#api-reference)

## LocalSocket

`LocalSocket` is an enum containing static helpers for Unix stream sockets. Use `SocketClient` or `SocketServer` for JSON framing and connection management.

### Construct an address

```swift
public static func address<T>(
  _ path: String,
  body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
) throws -> T
```

Constructs a `sockaddr_un` and passes its pointer and size to `body`. The pointer is valid only during the closure; do not store or return it. The method returns the closure's result and propagates its errors.

Empty paths, paths containing a null byte, and paths whose UTF-8 bytes plus a null terminator do not fit in `sun_path` throw `SocketError`.

### Connect to a socket

```swift
public static func connect(path: String, serviceName: String = "server") throws -> Int32
```

Creates and connects a socket, enables `SO_NOSIGPIPE`, and marks its descriptor close-on-exec. `serviceName` appears in connection failure messages. On failure, the helper closes the descriptor before throwing.

The caller owns the returned descriptor and must close it. Set send and receive timeouts on the descriptor if needed.

```swift
import Darwin
import StarkIPC

func connectAndClose(path: String) throws {
  let fd = try LocalSocket.connect(path: path)
  defer { close(fd) }
  // Perform raw socket operations here.
}
```

### Send bytes

```swift
public static func send(_ data: Data, to fd: Int32) throws
```

Writes all bytes, handling partial writes and retrying interrupted writes. Throws `SocketError` on other write failures. Some bytes may already have been sent when an error occurs. Add JSON encoding and a trailing newline yourself when sending to `SocketServer`. The caller still owns the descriptor.

## SocketError

```swift
public enum SocketError: LocalizedError {
  case message(String)
  public var errorDescription: String? { get }
}
```

`errorDescription` returns the associated message. Use `localizedDescription` when displaying it through an `Error` value.

Socket operations can also propagate other errors, including Foundation directory creation errors and JSON encoding or decoding errors. Avoid relying on exact error strings as a structured protocol.
