import Foundation

public enum SocketError: LocalizedError {
  case message(String)

  public var errorDescription: String? {
    switch self {
    case .message(let message): message
    }
  }
}
