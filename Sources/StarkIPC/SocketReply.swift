/// A response, whether to keep its connection open, and a callback after the send attempt.
public struct SocketReply<Response: Sendable>: Sendable {
  public let response: Response
  public let keepOpen: Bool
  public let onComplete: @Sendable () -> Void

  public init(
    _ response: Response,
    keepOpen: Bool = false,
    onComplete: @escaping @Sendable () -> Void = {}
  ) {
    self.response = response
    self.keepOpen = keepOpen
    self.onComplete = onComplete
  }
}
