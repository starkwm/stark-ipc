import Darwin
import Foundation
import StarkIPC
import Testing

@Suite("LocalSocket")
struct LocalSocketTests {
  @Test(
    "address: rejects empty, oversized, and NUL paths",
    arguments: ["", String(repeating: "x", count: 200), "/tmp/test\0ignored"]
  )
  func invalidPaths(path: String) {
    #expect(throws: (any Error).self) {
      try LocalSocket.address(path) { _, _ in }
    }
  }
}

@Suite("SocketClient")
struct SocketClientTests {
  @Test("receiveLine: rejects oversized replies")
  func replyLimit() throws {
    let directory = try socketDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let path = directory.appending(path: "control.sock").path
    let server = SocketServer<Int, String>(
      path: path,
      errorResponse: { $0.localizedDescription },
      handler: { _ in SocketReply(String(repeating: "x", count: 1_048_576)) }
    )

    try server.start()
    defer { server.stop() }

    let client = try SocketClient(path: path)
    try client.send(1)
    #expect(throws: (any Error).self) { try client.receiveLine() }
  }
}

@Suite("SocketServer", .serialized)
struct SocketServerTests {
  @Test("start: serves requests, protects the socket, and rejects a second server")
  func roundTrip() throws {
    let directory = try socketDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let path = directory.appending(path: "control.sock").path
    let server = testServer(path: path) { request in
      ControlResponse(value: .string(request.command))
    }

    try server.start()
    defer { server.stop() }

    let duplicate = testServer(path: path)
    #expect(throws: (any Error).self) { try duplicate.start() }

    let client = try SocketClient(path: path)
    try client.send(ControlRequest(command: "hello"))

    let response = try client.receive(ControlResponse.self)

    #expect(response.ok)
    #expect(response.value == .string("hello"))

    var info = stat()
    #expect(lstat(path, &info) == 0)
    #expect(info.st_mode & 0o777 == 0o600)

    server.stop()
    #expect(!FileManager.default.fileExists(atPath: path))
  }

  @Test("start: preserves an existing regular file")
  func preservesExistingFile() throws {
    let directory = try socketDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let path = directory.appending(path: "control.sock")
    try Data("keep".utf8).write(to: path)

    let server = testServer(path: path.path)
    #expect(throws: (any Error).self) { try server.start() }
    #expect(try String(contentsOf: path, encoding: .utf8) == "keep")
  }

  @Test("start: repeated starts and restart after stop succeed")
  func serverLifecycle() throws {
    let directory = try socketDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let path = directory.appending(path: "control.sock").path
    var server: SocketServer<ControlRequest, ControlResponse>? = testServer(path: path)

    try server?.start()
    try server?.start()

    server?.stop()
    server?.stop()

    try server?.start()

    server = nil
    #expect(!FileManager.default.fileExists(atPath: path))

    let replacement = testServer(path: path)
    try replacement.start()
    replacement.stop()
  }

  @Test("start: releases the lock after a failed start")
  func failedStartReleasesLock() throws {
    let directory = try socketDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let path = directory.appending(path: "control.sock").path
    let target = directory.appending(path: "keep")
    try Data("keep".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target.path)

    let server = testServer(path: path)
    #expect(throws: (any Error).self) { try server.start() }

    try FileManager.default.removeItem(atPath: path)
    try server.start()
    server.stop()

    try FileManager.default.removeItem(atPath: path + ".lock")
    try FileManager.default.createSymbolicLink(
      atPath: path + ".lock",
      withDestinationPath: target.path
    )
    #expect(throws: (any Error).self) { try server.start() }
    #expect(try String(contentsOf: target, encoding: .utf8) == "keep")

    try FileManager.default.removeItem(atPath: path + ".lock")
    try server.start()
    server.stop()
  }

  @Test("stop: preserves a replacement regular file")
  func preservesReplacementFile() throws {
    let directory = try socketDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let path = directory.appending(path: "control.sock")
    let server = testServer(path: path.path)
    try server.start()
    defer { server.stop() }

    try FileManager.default.removeItem(at: path)
    try Data("replacement".utf8).write(to: path)

    server.stop()
    #expect(try String(contentsOf: path, encoding: .utf8) == "replacement")
  }

  @Test("stop: preserves a replacement socket")
  func preservesReplacementSocket() throws {
    let directory = try socketDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let path = directory.appending(path: "control.sock").path
    let server = testServer(path: path)
    try server.start()
    defer { server.stop() }

    try FileManager.default.removeItem(atPath: path)
    let replacement = socket(AF_UNIX, SOCK_STREAM, 0)
    defer { close(replacement) }
    #expect(try LocalSocket.address(path) { bind(replacement, $0, $1) } == 0)

    var before = stat()
    #expect(lstat(path, &before) == 0)

    server.stop()

    var after = stat()
    #expect(lstat(path, &after) == 0)
    #expect(before.st_ino == after.st_ino)
  }

  @Test("publish: preserves the order of large replies")
  func publishedReplyOrder() throws {
    let directory = try socketDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let path = directory.appending(path: "control.sock").path
    let server = SocketServer<Int, String>(
      path: path,
      errorResponse: { $0.localizedDescription },
      handler: { _ in SocketReply("ready", keepOpen: true) }
    )

    try server.start()
    defer { server.stop() }

    let client = try SocketClient(path: path)
    try client.send(1)
    #expect(try client.receive(String.self) == "ready")

    let first = String(repeating: "a", count: 200_000)
    let second = String(repeating: "b", count: 200_000)
    server.publish(first)
    server.publish(second)

    #expect(try client.receive(String.self) == first)
    #expect(try client.receive(String.self) == second)
  }

  @Test(
    "readClient: assembles split requests and handles malformed JSON",
    arguments: [
      (#"{"command":"query","arguments":[]}"#, true),
      ("{broken}", false),
    ]
  )
  func splitRequests(payload: String, ok: Bool) throws {
    let directory = try socketDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let path = directory.appending(path: "control.sock").path
    let server = testServer(path: path)
    try server.start()
    defer { server.stop() }

    let fd = try LocalSocket.connect(path: path)
    defer { close(fd) }

    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    let bytes = Data(payload.utf8)
    try LocalSocket.send(bytes.prefix(2), to: fd)
    try LocalSocket.send(bytes.dropFirst(2) + Data([10]), to: fd)

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)

    while !data.contains(10) {
      let count = recv(fd, &buffer, buffer.count, 0)
      guard count > 0 else { throw SocketError.message("No response") }

      data.append(contentsOf: buffer.prefix(count))
    }

    #expect(try JSONDecoder().decode(ControlResponse.self, from: data).ok == ok)
  }

  @Test("readClient: completes replies after a client disconnects")
  func completionAfterDisconnect() throws {
    let directory = try socketDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let path = directory.appending(path: "control.sock").path
    let entered = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)
    let completed = DispatchSemaphore(value: 0)

    let server = SocketServer<ControlRequest, ControlResponse>(
      path: path,
      errorResponse: { ControlResponse(ok: false, error: $0.localizedDescription) },
      handler: { _ in
        entered.signal()
        await Task.detached { waitForSignal(proceed) }.value

        return SocketReply(ControlResponse(), onComplete: { completed.signal() })
      }
    )

    try server.start()
    defer { server.stop() }

    let fd = try LocalSocket.connect(path: path)
    try LocalSocket.send(Data(#"{"command":"anything","arguments":[]}"#.utf8) + Data([10]), to: fd)
    #expect(entered.wait(timeout: .now() + 2) == .success)

    close(fd)
    server.stop()
    proceed.signal()
    #expect(completed.wait(timeout: .now() + 2) == .success)
  }

  @Test("writeClient: completes large replies after sending")
  func largeReplyCompletion() throws {
    let directory = try socketDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let path = directory.appending(path: "control.sock").path
    let payload = String(repeating: "x", count: 800_000)
    let completed = DispatchSemaphore(value: 0)
    let server = SocketServer<Int, String>(
      path: path,
      errorResponse: { $0.localizedDescription },
      handler: { _ in SocketReply(payload, onComplete: { completed.signal() }) }
    )

    try server.start()
    defer { server.stop() }

    let client = try SocketClient(path: path)
    try client.send(1)
    #expect(completed.wait(timeout: .now() + 0.1) == .timedOut)
    #expect(try client.receive(String.self) == payload)
    #expect(completed.wait(timeout: .now() + 2) == .success)
    #expect(throws: (any Error).self) { try client.receiveLine() }
  }
}

@Suite("SocketServer deadlines")
struct SocketServerDeadlineTests {
  @Test("publish: subscribers outlive the initial request deadline")
  func subscriptionOutlivesRequestDeadline() throws {
    let directory = try socketDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let path = directory.appending(path: "control.sock").path
    let server = SocketServer<ControlRequest, ControlResponse>(
      path: path,
      errorResponse: { ControlResponse(ok: false, error: $0.localizedDescription) },
      handler: { _ in SocketReply(ControlResponse(value: .string("ready")), keepOpen: true) }
    )

    try server.start()
    defer { server.stop() }

    let client = try SocketClient(path: path)
    try client.send(ControlRequest(command: "arbitrary"))
    #expect(try client.receive(ControlResponse.self).value == .string("ready"))

    Thread.sleep(forTimeInterval: 5.1)

    server.publish(ControlResponse(value: .number(1)))
    server.publish(ControlResponse(value: .number(2)))

    #expect(try client.receive(ControlResponse.self).value == .number(1))
    #expect(try client.receive(ControlResponse.self).value == .number(2))

    server.stop()
    #expect(throws: (any Error).self) { try client.receiveLine() }
  }

  @Test("request handling: disconnects idle and oversized clients")
  func requestLimits() throws {
    let directory = try socketDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let path = directory.appending(path: "control.sock").path
    let server = testServer(path: path)
    try server.start()
    defer { server.stop() }

    for oversized in [true, false] {
      let fd = try LocalSocket.connect(path: path)
      defer { close(fd) }

      var timeout = timeval(tv_sec: 7, tv_usec: 0)
      setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

      if oversized { try? LocalSocket.send(Data(repeating: 65, count: 131_073), to: fd) }

      var byte: UInt8 = 0
      let count = recv(fd, &byte, 1, 0)
      #expect(count == 0 || (count < 0 && errno == ECONNRESET))
    }
  }

  @Test(
    "writeClient: a stalled subscriber does not block other requests",
    arguments: [false, true]
  )
  func stalledSubscriber(stop: Bool) throws {
    let directory = try socketDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let path = directory.appending(path: "control.sock").path
    let entered = DispatchSemaphore(value: 0)
    let completed = DispatchSemaphore(value: 0)
    let server = SocketServer<Int, String>(
      path: path,
      errorResponse: { $0.localizedDescription },
      handler: { request in
        if request == 1 {
          entered.signal()

          return SocketReply(
            String(repeating: "x", count: 800_000),
            keepOpen: true,
            onComplete: { completed.signal() }
          )
        }

        return SocketReply("ok")
      }
    )

    try server.start()
    defer { server.stop() }

    let stalled = try SocketClient(path: path)
    try stalled.send(1)
    #expect(entered.wait(timeout: .now() + 2) == .success)

    let client = try SocketClient(path: path)
    try client.send(2)
    #expect(try client.receive(String.self) == "ok")
    #expect(completed.wait(timeout: .now()) == .timedOut)

    if stop { server.stop() }

    #expect(completed.wait(timeout: .now() + 6) == .success)
    #expect(throws: (any Error).self) { try stalled.receiveLine() }
    #expect(completed.wait(timeout: .now()) == .timedOut)
  }
}

private func socketDirectory() throws -> URL {
  let directory = URL(fileURLWithPath: "/tmp/stark-ipc-" + UUID().uuidString.prefix(8))
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

  return directory
}

private func testServer(
  path: String,
  handler: @escaping @Sendable (ControlRequest) -> ControlResponse = { _ in ControlResponse() }
) -> SocketServer<ControlRequest, ControlResponse> {
  SocketServer(
    path: path,
    errorResponse: { ControlResponse(ok: false, error: $0.localizedDescription) },
    handler: { SocketReply(handler($0)) }
  )
}

private func waitForSignal(_ semaphore: DispatchSemaphore) {
  _ = semaphore.wait(timeout: .now() + 5)
}
