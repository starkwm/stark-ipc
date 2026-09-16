import Darwin
import Foundation
import Testing

@testable import StarkIPC

private func socketDirectory() throws -> URL {
  let directory = URL(fileURLWithPath: "/tmp/sborders-test-" + UUID().uuidString.prefix(8))
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}

@Test func roundTripAndExclusiveOwnership() async throws {
  let directory = try socketDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let path = directory.appending(path: "control.sock").path
  let server = testServer(path: path) { request in
    ControlResponse(value: .string(request.command))
  }
  try server.start()
  defer { server.stop() }
  let duplicate = testServer(path: path) { _ in ControlResponse() }
  #expect(throws: (any Error).self) { try duplicate.start() }
  let response = try await Task.detached {
    let client = try SocketClient(path: path)
    try client.send(ControlRequest(command: "hello"))
    return try client.receive(ControlResponse.self)
  }.value
  #expect(response.ok)
  if case .string(let value) = response.value {
    #expect(value == "hello")
  } else {
    Issue.record("Missing response")
  }
  var info = stat()
  #expect(lstat(path, &info) == 0)
  #expect(info.st_mode & 0o777 == 0o600)
  server.stop()
  #expect(!FileManager.default.fileExists(atPath: path))
}

@Test func refusesToReplaceAnExistingFile() throws {
  let directory = try socketDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let path = directory.appending(path: "control.sock")
  try Data("keep".utf8).write(to: path)
  let server = testServer(path: path.path) { _ in ControlResponse() }
  #expect(throws: (any Error).self) { try server.start() }
  #expect(try String(contentsOf: path, encoding: .utf8) == "keep")
}

@Test func acceptsSplitRequestsAndRejectsMalformedJSON() async throws {
  let directory = try socketDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let path = directory.appending(path: "control.sock").path
  let server = testServer(path: path) { _ in ControlResponse() }
  try server.start()
  defer { server.stop() }
  for payload in [#"{"command":"query","arguments":[]}"#, "{broken}"] {
    let ok = try await Task.detached {
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
      return try JSONDecoder().decode(ControlResponse.self, from: data).ok
    }.value
    #expect(ok == !payload.contains("broken"))
  }
}

@Test func rejectsOversizedSocketPathsAndEmbeddedNulls() {
  #expect(throws: (any Error).self) {
    try LocalSocket.address(String(repeating: "x", count: 200)) { _, _ in }
  }
  #expect(throws: (any Error).self) { try LocalSocket.address("/tmp/test\0ignored") { _, _ in } }
}

@Test func shutdownDoesNotDeleteAReplacementFile() throws {
  let directory = try socketDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let path = directory.appending(path: "control.sock")
  let server = testServer(path: path.path) { _ in ControlResponse() }
  try server.start()
  defer { server.stop() }
  try FileManager.default.removeItem(at: path)
  try Data("replacement".utf8).write(to: path)
  server.stop()
  #expect(try String(contentsOf: path, encoding: .utf8) == "replacement")
}

private func testServer(
  path: String,
  handler: @escaping @Sendable (ControlRequest) async -> ControlResponse
) -> SocketServer<ControlRequest, ControlResponse> {
  SocketServer(
    path: path,
    errorResponse: { ControlResponse(ok: false, error: $0.localizedDescription) },
    handler: { SocketReply(await handler($0)) }
  )
}

@Test func streamingSurvivesRequestDeadlineAndReceivesMultipleFrames() throws {
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

@Test func stopAndRestartAndDeinitialisationReleaseOwnership() throws {
  let directory = try socketDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let path = directory.appending(path: "control.sock").path
  var server: SocketServer<ControlRequest, ControlResponse>? = testServer(path: path) { _ in
    ControlResponse()
  }
  try server?.start()
  try server?.start()
  server?.stop()
  server?.stop()
  try server?.start()
  server = nil
  #expect(!FileManager.default.fileExists(atPath: path))
  let replacement = testServer(path: path) { _ in ControlResponse() }
  try replacement.start()
  replacement.stop()
}

@Test func refusesSymlinksAndReleasesLockAfterFailedStart() throws {
  let directory = try socketDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let path = directory.appending(path: "control.sock").path
  let target = directory.appending(path: "keep")
  try Data("keep".utf8).write(to: target)
  try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target.path)
  let server = testServer(path: path) { _ in ControlResponse() }
  #expect(throws: (any Error).self) { try server.start() }
  try FileManager.default.removeItem(atPath: path)
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

@Test func oversizedAndIdleRequestsDisconnect() throws {
  let directory = try socketDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let path = directory.appending(path: "control.sock").path
  let server = testServer(path: path) { _ in ControlResponse() }
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

@Test func completionRunsAfterReplyEvenWhenClientDisconnects() throws {
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

private func waitForSignal(_ semaphore: DispatchSemaphore) {
  _ = semaphore.wait(timeout: .now() + 5)
}

@Test func shutdownDoesNotDeleteAReplacementSocket() throws {
  let directory = try socketDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let path = directory.appending(path: "control.sock").path
  let server = testServer(path: path) { _ in ControlResponse() }
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

@Test func transportAcceptsMessagesWithoutCommands() throws {
  let directory = try socketDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let path = directory.appending(path: "control.sock").path
  let server = SocketServer<Int, String>(
    path: path,
    errorResponse: { $0.localizedDescription },
    handler: { SocketReply("value=\($0)") }
  )
  try server.start()
  defer { server.stop() }
  let client = try SocketClient(path: path)
  try client.send(42)
  #expect(try client.receive(String.self) == "value=42")
}
