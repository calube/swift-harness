import Foundation

/// The simulator an area's `xcodebuild test` command names by `-destination ...,name=<device>`.
/// Run as written, every session shares that 1 device; the command is instead pointed at a
/// leased clone of it by ``leased(_:udid:)``.
public struct XcodeTestDestination: Sendable, Hashable {
  /// `iPhone 17` from `name=iPhone 17`.
  public let device: String
  /// `26.2` from `OS=26.2`; `nil` when the destination names no version, or names `latest`.
  public let os: String?

  public init(device: String, os: String?) {
    self.device = device
    self.os = os
  }

  /// The `xcodebuild` actions that launch a test runner on the destination.
  static let testActions: Set<String> = ["test", "test-without-building"]

  /// The simulator `command`'s test run names; `nil` when it runs no test on a named simulator,
  /// or names it in a spelling ``leased(_:udid:)`` can't rewrite.
  public static func simulator(in command: String) -> XcodeTestDestination? {
    named(in: command)?.destination
  }

  /// `command` with each `-destination` naming ``simulator(in:)``'s device replaced by
  /// `id=<udid>`; `nil` when it can't be rewritten exactly as written.
  public static func leased(_ command: String, udid: String) -> String? {
    guard let named = named(in: command) else { return nil }
    return named.values.reduce(command) { text, value in
      text.replacingOccurrences(of: value, with: "id=\(udid)")
    }
  }

  /// The 1 simulator every test-running `xcodebuild` in `command` names, with each distinct
  /// `-destination` value as written. The text must hold each value exactly as often as the
  /// commands pass it, so replacing it touches nothing else.
  private static func named(in command: String) -> (
    destination: XcodeTestDestination, values: [String]
  )? {
    var found: [(destination: XcodeTestDestination, value: String)] = []
    for invocation in ShellSyntax.simpleCommands(in: command) where invocation.name == "xcodebuild" {
      let arguments = invocation.arguments
      let runsTests = arguments.indices.contains { index in
        testActions.contains(arguments[index])
          && (index == 0 || !XcodeBuildForTesting.takesValue(arguments[index - 1]))
      }
      guard runsTests else { continue }
      for index in arguments.indices.dropLast() where arguments[index] == "-destination" {
        let value = arguments[index + 1]
        guard let destination = parse(value) else { return nil }
        found.append((destination, value))
      }
    }
    guard let first = found.first?.destination,
      found.allSatisfy({ $0.destination == first })
    else { return nil }
    var values: [String] = []
    for value in found.map(\.value) where !values.contains(value) {
      let passed = found.filter { $0.value == value }.count
      guard command.components(separatedBy: value).count - 1 == passed else { return nil }
      values.append(value)
    }
    return (first, values)
  }

  /// `platform=iOS Simulator,name=iPhone 17[,OS=26.2]`; `nil` for any destination that isn't a
  /// simulator named by `name=`.
  private static func parse(_ value: String) -> XcodeTestDestination? {
    var keys: [String: String] = [:]
    for pair in value.split(separator: ",") {
      guard let equals = pair.firstIndex(of: "=") else { return nil }
      let key = pair[..<equals].trimmingCharacters(in: .whitespaces)
      keys[key] = pair[pair.index(after: equals)...].trimmingCharacters(in: .whitespaces)
    }
    guard keys["platform"]?.hasSuffix("Simulator") == true, keys["id"] == nil,
      let device = keys["name"], !device.isEmpty
    else { return nil }
    let os = keys["OS"].flatMap { $0 == "latest" || $0.isEmpty ? nil : $0 }
    return XcodeTestDestination(device: device, os: os)
  }
}
