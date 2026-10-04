import Foundation

/// One macOS `.ips` crash report, as far as `sim` reads it: whose process crashed, on which
/// device, when, and how.
///
/// The file is a 1-line JSON header followed by a JSON body. Only the body's `procName`,
/// `procPath`, `bundleInfo.CFBundleIdentifier`, `captureTime` and `exception` are read.
public struct SimCrashReport: Sendable, Equatable {
  /// Where `sim down` puts the run's crash reports, inside the run's `sim/` folder.
  public static let directoryName = "crashes"
  public static let fileExtension = "ips"

  public var processName: String
  /// The crashed executable's path, which names the simulator device it ran on.
  public var processPath: String
  public var bundleID: String
  /// When the process crashed.
  public var captureTime: Date
  /// `exception.type`, with `exception.signal` when there is one, such as `EXC_CRASH (SIGABRT)`.
  public var exception: String?

  public init(
    processName: String, processPath: String, bundleID: String, captureTime: Date,
    exception: String?
  ) {
    self.processName = processName
    self.processPath = processPath
    self.bundleID = bundleID
    self.captureTime = captureTime
    self.exception = exception
  }

  /// `crashes/<name>`.
  public static func path(fileName: String) -> String {
    "\(directoryName)/\(fileName)"
  }

  public static func parse(_ data: Data) throws(SimCrashReportError) -> SimCrashReport {
    throw .malformed("not implemented")
  }

  /// Whether the report is the run's app crashing on the run's device after the run started.
  public func belongs(to session: SimSession) -> Bool {
    false
  }
}

public enum SimCrashReportError: Error, Sendable, Equatable {
  /// Not a header line followed by a JSON body, or a key holds the wrong type.
  case malformed(String)
  case missingKey(String)
  /// A time that doesn't read as `yyyy-MM-dd HH:mm:ss[.fraction] ±hhmm`.
  case invalidTime(String)

  public var message: String {
    switch self {
    case .malformed(let detail): "not a crash report: \(detail)"
    case .missingKey(let key): "crash report has no \"\(key)\""
    case .invalidTime(let value): "crash report time \"\(value)\" doesn't read"
    }
  }
}

/// `sim.app-exited`: a step that found the app not running, or a crash report of the run's app.
public enum SimExitRule {
  /// The findings over `evidence`: 1 per step where the app was found not running after a step
  /// where it ran, each naming the run's next crash report in time order, then 1 per crash report
  /// left over. A crash report of another app, device or an earlier run is ignored; one that
  /// can't be read or parsed is `sim.evidence-missing`.
  public static func findings(_ evidence: SimEvidence) -> [SimEvidenceFinding] {
    []
  }
}
