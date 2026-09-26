import Foundation
import SwiftGateDomain
import TOML

/// Decodes `.swiftgate.toml` with swift-toml into a ``ConfigValue`` tree, then validates it with
/// ``ConfigSchema``. Decoding to a tree rather than straight into `Codable` structs is what lets
/// validation see unknown keys and report every problem at once.
public struct TOMLConfigDecoder: ConfigDecoding {
  public init() {}

  public func decode(_ text: String) throws(ConfigLoadError) -> Config {
    let document: ConfigValue
    do {
      document = try TOMLDecoder().decode(DecodedValue.self, from: text).value
    } catch let TOMLDecodingError.invalidSyntax(line, column, message) {
      throw .syntax(line: line, column: column, message: message)
    } catch {
      throw .syntax(line: 0, column: 0, message: String(describing: error))
    }
    do {
      return try ConfigSchema.config(from: document)
    } catch {
      throw .invalid(error)
    }
  }
}

/// swift-toml 2.0 exposes its parsed tree (`TOMLValue`) only through `Decodable`, so this probes
/// the decoder's containers to rebuild it. Probe order matters: `Double` also accepts integers,
/// so `Int64` is tried first.
private struct DecodedValue: Decodable {
  let value: ConfigValue

  init(from decoder: any Decoder) throws {
    if let keyed = try? decoder.container(keyedBy: AnyKey.self) {
      var table: [String: ConfigValue] = [:]
      for key in keyed.allKeys {
        table[key.stringValue] = try keyed.decode(DecodedValue.self, forKey: key).value
      }
      value = .table(table)
    } else if var unkeyed = try? decoder.unkeyedContainer() {
      var array: [ConfigValue] = []
      while !unkeyed.isAtEnd {
        array.append(try unkeyed.decode(DecodedValue.self).value)
      }
      value = .array(array)
    } else {
      let single = try decoder.singleValueContainer()
      if let bool = try? single.decode(Bool.self) {
        value = .boolean(bool)
      } else if let integer = try? single.decode(Int64.self) {
        value = .integer(integer)
      } else if let double = try? single.decode(Double.self) {
        value = .float(double)
      } else if let string = try? single.decode(String.self) {
        value = .string(string)
      } else {
        value = .unsupported(typeName: Self.dateTimeTypeName(single))
      }
    }
  }

  private static func dateTimeTypeName(_ single: any SingleValueDecodingContainer) -> String {
    if (try? single.decode(LocalDate.self)) != nil { return "local date" }
    if (try? single.decode(LocalTime.self)) != nil { return "local time" }
    if (try? single.decode(LocalDateTime.self)) != nil { return "local date-time" }
    return "date-time"
  }
}

private struct AnyKey: CodingKey {
  let stringValue: String
  var intValue: Int? { nil }

  init(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { nil }
}
