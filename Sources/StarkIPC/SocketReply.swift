/// The application chooses connection lifetime and any action after attempting the reply.
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
