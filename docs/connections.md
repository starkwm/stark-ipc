# Connections and subscriptions

[Documentation index](index.md)

## Send a request

StarkIPC uses Unix stream sockets and newline-delimited JSON. Each connection accepts one request. The application defines command names and response meanings.

Create a `SocketClient`, send the request, and read the response. The server closes the connection after its reply by default. Open another connection to send another request. See [getting started](getting-started.md) for a complete example.

## Subscribe to updates

Return a `SocketReply` with `keepOpen: true` from the server's handler. The server sends the initial response and keeps the connection open for calls to `publish(_:)`.

Create the client with `streaming: true`, then call `receive(_:)` or `receiveLine()` for each response. The first call reads the initial reply; later calls read published updates. These calls block the calling thread, so run them where waiting for data is acceptable.

`publish(_:)` sends to all current subscribers. It does not filter by topic or replay earlier responses. See the [server example](api/socket-server.md#publish-updates) and [client example](api/socket-client.md#receive-subscription-updates).

## Socket ownership

The server sets socket permissions to `0600` and accepts only peers whose user ID matches its own. A lock file at `path + ".lock"` prevents another server from claiming the same path.

Call `stop()` to disconnect clients, remove the socket the server owns, and release its lock. The lock file remains on disk. Deinitializing the server also stops it.

## Timeouts and limits

The server accepts at most 32 concurrent connections. It disconnects clients whose buffered request exceeds 131,072 bytes, or whose connection has not become a subscription within five seconds of acceptance. That deadline includes handler execution.

The client sets a five-second send timeout and, by default, a five-second receive timeout. `streaming: true` disables the receive timeout. The client rejects a response buffer larger than 1,048,576 bytes. Both buffer limits include any newline or additional data in the buffer.

Server writes use nonblocking sockets. When a socket is temporarily full, the server waits for it to become writable and resumes the reply. Each connection can queue up to 256 responses with at most 1,048,576 unsent bytes, including newlines. Exceeding either limit disconnects the client. A pending write queue must drain within five seconds of first waiting for a writable socket, including for subscriptions. Other write failures also disconnect the client. There is no delivery acknowledgement.
