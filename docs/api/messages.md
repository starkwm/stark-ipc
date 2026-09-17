# Message types

[Documentation index](../index.md#api-reference)

These types provide an optional shared message format. StarkIPC does not interpret command names or enforce relationships between response fields.

## ControlRequest

`ControlRequest` conforms to `Codable` and `Sendable`.

```swift
public var command: String
public var arguments: [String]
public var value: JSONValue?

public init(command: String, arguments: [String] = [], value: JSONValue? = nil)
```

`command` names an application-defined operation. `arguments` carries string arguments, and `value` carries an optional JSON payload.

```json
{"command":"focus","arguments":["next"],"value":{"wrap":true}}
```

When decoding JSON, `command` and `arguments` are required. The initializer's default arguments do not supply missing JSON fields. `value` may be absent or null.

## ControlResponse

`ControlResponse` conforms to `Codable` and `Sendable`. Its properties are immutable.

```swift
public let ok: Bool
public let value: JSONValue?
public let error: String?

public init(ok: Bool = true, value: JSONValue? = nil, error: String? = nil)
```

Use `ok` to report application success, `value` for a result, and `error` for an error message. Setting `error` does not automatically set `ok` to `false`.

```json
{"ok":true,"value":"pong"}
```

```json
{"ok":false,"error":"Unknown command"}
```

When decoding JSON, `ok` is required. `value` and `error` may be absent or null. Encoding either message type omits optional fields whose value is `nil`.

## JSONValue

`JSONValue` conforms to `Codable`, `Equatable`, and `Sendable`.

```swift
public enum JSONValue: Codable, Equatable, Sendable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case object([String: JSONValue])
  case array([JSONValue])
  case null
}
```

Values encode as ordinary JSON, without enum case names or wrapper objects. Numbers use `Double`, so use a custom payload type if your application needs exact integers beyond its precision.

`JSONValue` implements the standard `init(from:)` and `encode(to:)` Codable methods. A standalone JSON null decodes as `.null`. For the optional `value` field of a control message, both a missing field and a JSON null decode as `nil`. Setting that field to `.null` explicitly encodes a JSON null.
