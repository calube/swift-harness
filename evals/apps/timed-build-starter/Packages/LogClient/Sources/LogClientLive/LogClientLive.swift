import Dependencies
import LogClient
import OSLog

enum OSLogRendering {
  struct Segments: Equatable {
    var publicText = ""
    var privateText = ""
    var sensitiveText = ""
  }

  static func segments(for attributes: [LogAttribute]) -> Segments {
    func render(_ privacy: LogPrivacy) -> String {
      attributes.filter { $0.privacy == privacy }.map { "\($0.key)=\($0.value)" }.joined(
        separator: " ")
    }
    return Segments(
      publicText: render(.public),
      privateText: render(.private),
      sensitiveText: render(.sensitive)
    )
  }

  static func type(for level: LogLevel) -> OSLogType {
    switch level {
    case .debug: .debug
    case .info: .info
    case .notice: .default
    case .error: .error
    case .fault: .fault
    }
  }

  static func severity(of level: LogLevel) -> Int {
    switch level {
    case .debug: 0
    case .info: 1
    case .notice: 2
    case .error: 3
    case .fault: 4
    }
  }
}

extension LogClient {
  /// Each privacy class is interpolated as its own OSLog argument so the unified logging system
  /// redacts private and sensitive values exactly as a direct `Logger` call would.
  public static func osLog(subsystem: String, minimumLevel: LogLevel = .debug) -> Self {
    let minimum = OSLogRendering.severity(of: minimumLevel)
    return Self(
      isEnabled: { level, _ in OSLogRendering.severity(of: level) >= minimum },
      emit: { record in
        let segments = OSLogRendering.segments(for: record.attributes)
        Logger(subsystem: subsystem, category: record.category).log(
          level: OSLogRendering.type(for: record.level),
          "\(record.message, privacy: .public) \(segments.publicText, privacy: .public) \(segments.privateText, privacy: .private) \(segments.sensitiveText, privacy: .sensitive)"
        )
      }
    )
  }
}

extension LogClient: DependencyKey {
  public static let liveValue = LogClient.osLog(subsystem: "com.example.TimedBuildStarter")
}
