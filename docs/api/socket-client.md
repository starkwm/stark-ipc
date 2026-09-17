# SocketClient

[Documentation index](../index.md#api-reference)

`SocketClient` is a synchronous final class. Use each instance from one caller. It does not conform to `Sendable`, and its methods block the calling thread.

## Connect to a server

```swift
public init(
  path: String,
  serviceName: String = "server",
  streaming: Bool = false
) throws
```

Connect to `path` when creating the client. `serviceName` appears in connection failure messages. The client sets a five-second send timeout. It also sets a five-second receive timeout unless `streaming` is `true`.

Deinitializing the client closes its file descriptor. There is no public close method.

## Send a request

```swift
public func send<Request: Encodable>(_ request: Request) throws
```

Encode the request with a default `JSONEncoder`, append a newline, and write the bytes. Encoding and socket errors propagate to the caller. Send only one request per connection when using `SocketServer`.

## Receive a response

```swift
public func receive<Response: Decodable>(_ type: Response.Type) throws -> Response
public func receiveLine() throws -> Data
```

`receive(_:)` reads one line and decodes it with a default `JSONDecoder`. Decoding errors propagate to the caller.

`receiveLine()` returns the original bytes without the trailing newline. It preserves unread bytes for the next call, which lets subscription clients receive multiple responses from one connection. It throws `SocketError` if the connection closes, a read fails or times out, or the response buffer exceeds 1,048,576 bytes. A connection closing before a newline does not produce a partial response.

```swift
import StarkIPC

let client = try SocketClient(path: "/tmp/example.sock")
try client.send(ControlRequest(command: "ping"))
let response = try client.receive(ControlResponse.self)
```

## Receive subscription updates

```swift
import StarkIPC

let client = try SocketClient(path: "/tmp/example.sock", streaming: true)
try client.send(ControlRequest(command: "subscribe"))

while true {
  let response = try client.receive(ControlResponse.self)
  print(response)
}
```

The server's handler must return `keepOpen: true` for this command. The first receive reads the initial reply; subsequent calls read published updates. With no receive timeout, a call can block until data arrives or the connection closes. Run this synchronous loop on a thread where blocking is acceptable.
