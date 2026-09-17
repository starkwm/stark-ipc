# API reference

[Documentation index](../index.md#api-reference)

All public types are available through `import StarkIPC`.

| Type | Purpose |
| --- | --- |
| [SocketClient](socket-client.md) | Send an encodable request and read JSON response lines. |
| [SocketServer](socket-server.md) | Decode requests and deliver responses from an asynchronous handler. |
| [SocketReply](socket-server.md#socketreply) | Set a response, connection lifetime, and completion action. |
| [ControlRequest](messages.md#controlrequest) | Carry a command, string arguments, and an optional JSON value. |
| [ControlResponse](messages.md#controlresponse) | Carry success status, an optional JSON value, and an optional error message. |
| [JSONValue](messages.md#jsonvalue) | Represent JSON values without a custom payload type. |
| [LocalSocket](local-socket.md#localsocket) | Build socket addresses, connect, and write raw bytes. |
| [SocketError](local-socket.md#socketerror) | Report a transport error as a localized message. |

## Custom messages

The server accepts any `Decodable & Sendable` request and `Encodable & Sendable` response. A client requires `Encodable` to send and `Decodable` to receive. Both processes must agree on the JSON format.

For example, a `SocketServer<Int, String>` can receive the JSON number `42` and reply with the JSON string `"value=42"`.

See [connections and subscriptions](../connections.md) for message framing, timeouts, and limits.
