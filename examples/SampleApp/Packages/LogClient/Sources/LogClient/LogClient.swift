import Dependencies
import DependenciesMacros

public enum LogLevel: Sendable, Equatable { case debug, info, notice, error, fault }

public enum LogPrivacy: Sendable, Equatable { case `public`, `private`, sensitive }

public struct LogAttribute: Sendable, Equatable {
  public let key: String
  public let value: String
  public let privacy: LogPrivacy

  public init(key: String, value: String, privacy: LogPrivacy) {
    self.key = key
    self.value = value
    self.privacy = privacy
  }

  public static func `public`(_ k: String, _ v: some CustomStringConvertible) -> Self {
    .init(key: k, value: "\(v)", privacy: .public)
  }
  public static func `private`(_ k: String, _ v: some CustomStringConvertible) -> Self {
    .init(key: k, value: "\(v)", privacy: .private)
  }
  public static func sensitive(_ k: String, _ v: some CustomStringConvertible) -> Self {
    .init(key: k, value: "\(v)", privacy: .sensitive)
  }
}

public struct LogRecord: Sendable, Equatable {
  public let level: LogLevel
  public let category: String
  public let message: String
  public let attributes: [LogAttribute]

  public init(level: LogLevel, category: String, message: String, attributes: [LogAttribute]) {
    self.level = level
    self.category = category
    self.message = message
    self.attributes = attributes
  }
}

@DependencyClient
public struct LogClient: Sendable {
  public var isEnabled: @Sendable (_ level: LogLevel, _ category: String) -> Bool = { _, _ in false }
  public var emit: @Sendable (_ record: LogRecord) -> Void
}

extension LogClient {
  /// `message` is a `StaticString` so user data can only enter through privacy-tagged attributes.
  public func log(
    _ level: LogLevel,
    _ message: StaticString,
    category: String,
    _ attributes: @autoclosure () -> [LogAttribute] = []
  ) {
    guard isEnabled(level, category) else { return }
    emit(LogRecord(level: level, category: category, message: "\(message)", attributes: attributes()))
  }
}

extension LogClient: TestDependencyKey {
  /// Logging is everywhere, so an unimplemented test value would fail every test that touches it.
  /// Tests that assert a path logs override `emit` with a recorder.
  public static let testValue = Self(isEnabled: { _, _ in true }, emit: { _ in })
}

extension DependencyValues {
  public var logClient: LogClient {
    get { self[LogClient.self] }
    set { self[LogClient.self] = newValue }
  }
}
