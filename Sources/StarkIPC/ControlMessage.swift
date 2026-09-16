import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case object([String: JSONValue])
  case array([JSONValue])
  case null

  public init(from decoder: any Decoder) throws {
    let value = try decoder.singleValueContainer()

    if value.decodeNil() {
      self = .null
    } else if let v = try? value.decode(Bool.self) {
      self = .bool(v)
    } else if let v = try? value.decode(Double.self) {
      self = .number(v)
    } else if let v = try? value.decode(String.self) {
      self = .string(v)
    } else if let v = try? value.decode([String: JSONValue].self) {
      self = .object(v)
    } else {
      self = .array(try value.decode([JSONValue].self))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()

    switch self {
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }
}

public struct ControlRequest: Codable, Sendable {
  public var command: String
  public var arguments: [String]
  public var value: JSONValue?

  public init(command: String, arguments: [String] = [], value: JSONValue? = nil) {
    self.command = command
    self.arguments = arguments
    self.value = value
  }
}

public struct ControlResponse: Codable, Sendable {
  public let ok: Bool
  public let value: JSONValue?
  public let error: String?

  public init(ok: Bool = true, value: JSONValue? = nil, error: String? = nil) {
    self.ok = ok
    self.value = value
    self.error = error
  }
}
