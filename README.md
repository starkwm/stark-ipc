# StarkIPC

A Swift package for same-user Unix socket control connections on macOS. The package, library product and import module are named `StarkIPC`. Its manifest requires Swift tools 6.2 and macOS 26.

`LocalSocket` provides validated Unix addresses, connection setup and complete writes with interrupted-write retries. `SocketClient` sends newline-delimited JSON and reads complete response lines, retaining the original JSON bytes for CLI output. Use `streaming: true` to disable its receive timeout for subscriptions. Confine each client to one caller.

`SocketServer<Request, Response>` accepts any `Decodable & Sendable` request and `Encodable & Sendable` response. Supply an async handler and an error-response factory. The handler returns `SocketReply`, whose `keepOpen` flag retains a connection for `publish`. Its optional `onComplete` callback runs on the server queue after attempting the reply, including when the client has disconnected. It also runs for an in-flight handler after `stop`, provided the server still exists. It must not block. Calling `stop` from this callback is supported.

The server accepts one request per connection. Retained connections receive server publications; sending another request disconnects them. Call `stop` to close all connections and release ownership. Deinitialisation also stops the server. A stopped server can restart.

`ControlRequest`, `ControlResponse` and `JSONValue` retain the existing sbar and sborders wire formats. They are optional conveniences; the transport does not interpret commands. Applications own socket paths, routing, subscription policy, stop actions, CLI printing and exit status. `serviceName` changes diagnostic text only.

## Limits and ownership

The server retains the consumers' existing limits: 32 connections, a listen backlog of 16, 131,072 buffered request bytes and a five-second deadline for non-streaming connections. The client allows 1,048,576 buffered response bytes and uses five-second send and receive timeouts, except for streaming receives. These limits apply to buffered data, including the newline. Slow receivers disconnect on a failed nonblocking write; the server does not maintain an unbounded output queue.

Socket paths reject empty strings, embedded nulls and addresses exceeding `sockaddr_un.sun_path`. Ownership uses a non-following lock-file open and exclusive advisory lock. The server refuses to replace non-sockets or sockets belonging to another user, creates the socket with mode 0600, and checks peer user IDs. Cleanup removes only the device/inode identity bound by this server. The lock file remains for subsequent starts. Interrupted reads and writes are retried without disconnecting clients.

This implementation uses Darwin APIs. It does not yet support Linux or swm's distinct versioned protocol.

## Validation

```sh
swift test --disable-xctest --no-parallel
swift format lint -r Sources Tests Package.swift
```

Tests combine the consumers' socket cases with subscription deadlines, restart, deinitialisation, symlink refusal, request limits and completion after disconnect. Consumer integration tests also exercise app-specific stop and subscription policies.
