# SocketServer and SocketReply

[Documentation index](../index.md#api-reference)

## SocketServer

```swift
public final class SocketServer<
  Request: Decodable & Sendable,
  Response: Encodable & Sendable
>: @unchecked Sendable
```

The server manages connections on an internal serial dispatch queue. It runs each valid request's handler in a separate task. Switch to the main actor when accessing main-actor state. Handlers for different connections can overlap.

### Create a server

```swift
public init(
  path: String,
  serviceName: String = "server",
  errorResponse: @escaping @Sendable (any Error) -> Response,
  handler: @escaping @Sendable (Request) async -> SocketReply<Response>
)
```

`path` identifies the socket. `serviceName` appears in the socket ownership error. Initialization stores the configuration. Call `start()` to listen.

`errorResponse` converts request decoding errors into a response, which the server attempts to send before closing the connection. It runs on the internal queue. Other transport failures can close the connection without a response.

`handler` receives a decoded request and returns a reply. It cannot throw. Catch application errors inside the handler and include them in your response.

### Start and stop the server

```swift
public func start() throws
public func stop()
```

`start()` validates the path, creates its parent directory if needed, and acquires an exclusive lock at `path + ".lock"`. It can replace an existing socket owned by the current user, but refuses to replace a regular file, a symbolic link, or another user's socket. Startup failures throw.

Calling `start()` while listening has no effect. `stop()` cancels the listener and client connections, removes the socket if it still matches the one the server created, and releases the lock. The lock file remains on disk. Repeated calls to `stop()` are safe, and the same server can start again afterward. Deinitialization also calls `stop()`.

Stopping does not cancel an application handler already running. Keep the server alive for as long as it should accept requests.

### Publish updates

```swift
public func publish(_ response: Response)
```

Queues a response for every connection subscribed when the queued operation runs. It returns without waiting for writes and provides no delivery result. The server does not replay earlier responses to new subscribers.

A handler subscribes its connection by returning a reply with `keepOpen: true`. The server sends that reply's response first. Published updates use the same `Response` type. There are no built-in topics or subscription filters.

```swift
import Foundation
import StarkIPC

let server = SocketServer<ControlRequest, ControlResponse>(
  path: "/tmp/example.sock",
  errorResponse: { ControlResponse(ok: false, error: $0.localizedDescription) },
  handler: { request in
    if request.command == "subscribe" {
      return SocketReply(ControlResponse(value: .string("ready")), keepOpen: true)
    }

    return SocketReply(ControlResponse(ok: false, error: "Unknown command"))
  }
)
try server.start()

// Publish when an application event occurs after a client has subscribed.
server.publish(ControlResponse(value: .string("changed")))
```

## SocketReply

```swift
public struct SocketReply<Response: Sendable>: Sendable {
  public let response: Response
  public let keepOpen: Bool
  public let onComplete: @Sendable () -> Void

  public init(
    _ response: Response,
    keepOpen: Bool = false,
    onComplete: @escaping @Sendable () -> Void = {}
  )
}
```

`response` is the initial response. `keepOpen` defaults to `false`, so the server closes the connection after attempting the reply. Set it to `true` to receive future calls to `publish(_:)`.

`onComplete` runs on the server's internal queue after the server writes the reply to the socket, or when writing fails or the connection disappears. It waits for buffered writes but does not confirm that the client received the response. It may not run if the server has been deallocated.

Keep the callback short. Do not call `start()` from it because `start()` synchronously enters that same queue.
