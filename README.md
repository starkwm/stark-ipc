# StarkIPC

Swift utilities for sending JSON requests and responses over Unix sockets between processes running as the same user.

Requires Swift 6.2 and macOS 26.

## Usage

Add `https://github.com/starkwm/stark-ipc.git` as a Swift package dependency and link the `StarkIPC` product to your target.

### Start a server

Create and keep the server in your application. Supply a request handler and a response for errors:

```swift
import Foundation
import StarkIPC

let path = FileManager.default.temporaryDirectory
  .appendingPathComponent("example.sock").path

let server = SocketServer<ControlRequest, ControlResponse>(
  path: path,
  errorResponse: { error in
    ControlResponse(ok: false, error: error.localizedDescription)
  },
  handler: { request in
    switch request.command {
    case "ping":
      SocketReply(ControlResponse(value: .string("pong")))
    default:
      SocketReply(ControlResponse(ok: false, error: "Unknown command"))
    }
  }
)
try server.start()
```

The server accepts one request per connection. Call `server.stop()` to close connections and release the socket.

### Send a request

Connect to the same socket path from another process:

```swift
import Foundation
import StarkIPC

let path = FileManager.default.temporaryDirectory
  .appendingPathComponent("example.sock").path

let client = try SocketClient(path: path)
try client.send(ControlRequest(command: "ping"))
let response = try client.receive(ControlResponse.self)
```

The client is synchronous. Use each instance from one caller. Use `receiveLine()` to read the original JSON bytes instead of decoding a response.

For subscriptions, return a `SocketReply` with `keepOpen: true` and send updates with `server.publish(_:)`. Create the client with `streaming: true` to disable its receive timeout, then receive each update on the same connection.

`ControlRequest`, `ControlResponse` and `JSONValue` provide a shared message format. You can also use your own request and response types. Server requests must conform to `Decodable & Sendable`, and responses to `Encodable & Sendable`.
