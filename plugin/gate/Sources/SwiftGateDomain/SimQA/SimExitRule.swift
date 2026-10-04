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
    guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else {
      throw .malformed("no header line")
    }
    let parsed: Any
    do {
      parsed = try JSONSerialization.jsonObject(with: data[data.index(after: newline)...])
    } catch {
      throw .malformed("the body after the header line is not JSON")
    }
    guard let body = parsed as? [String: Any] else {
      throw .malformed("the body is not a JSON object")
    }
    func text(_ value: Any?, _ key: String) throws(SimCrashReportError) -> String {
      guard let value else { throw .missingKey(key) }
      guard let string = value as? String, !string.isEmpty else {
        throw .malformed("\"\(key)\" is not a non-empty string")
      }
      return string
    }
    let bundleInfo = body["bundleInfo"] as? [String: Any]
    let time = try text(body["captureTime"], "captureTime")
    guard let captureTime = Self.time(time) else { throw .invalidTime(time) }
    var exception: String?
    if let raw = body["exception"] as? [String: Any], let type = raw["type"] as? String {
      exception = (raw["signal"] as? String).map { "\(type) (\($0))" } ?? type
    }
    return SimCrashReport(
      processName: try text(body["procName"], "procName"),
      processPath: try text(body["procPath"], "procPath"),
      bundleID: try text(bundleInfo?["CFBundleIdentifier"], "bundleInfo.CFBundleIdentifier"),
      captureTime: captureTime, exception: exception)
  }

  /// Whether the report is the run's app crashing on the run's device after the run started.
  /// `session.json` keeps whole seconds, so a crash in `startedAt`'s second counts.
  public func belongs(to session: SimSession) -> Bool {
    bundleID == session.bundleID
      && processPath.contains("/CoreSimulator/Devices/\(session.udid)/")
      && captureTime >= session.startedAt
  }

  /// `yyyy-MM-dd HH:mm:ss[.fraction] ±hhmm`, with any number of fraction digits.
  static func time(_ text: String) -> Date? {
    let parts = text.split(separator: " ")
    guard parts.count == 3 else { return nil }
    let clock = parts[1].split(separator: ".", maxSplits: 1)
    var fraction = 0.0
    if clock.count == 2 {
      guard clock[1].allSatisfy(\.isASCII), clock[1].allSatisfy(\.isNumber),
        let value = Double("0.\(clock[1])")
      else { return nil }
      fraction = value
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
    guard let whole = formatter.date(from: "\(parts[0]) \(clock[0]) \(parts[2])") else {
      return nil
    }
    return whole.addingTimeInterval(fraction)
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
    var findings: [SimEvidenceFinding] = []
    var reports: [(path: String, report: SimCrashReport)] = []
    for (path, file) in evidence.crashReports.sorted(by: { $0.key < $1.key }) {
      func unreadable(_ why: String) -> SimEvidenceFinding {
        SimEvidenceFinding(
          rule: .evidenceMissing, step: nil, path: path,
          message: "run \(evidence.runID): \(path) \(why)")
      }
      switch file {
      case .unreadable(let reason):
        findings.append(unreadable("can't be read: \(reason)"))
      case .present(let data):
        do throws(SimCrashReportError) {
          let report = try SimCrashReport.parse(data)
          if report.belongs(to: evidence.session) { reports.append((path, report)) }
        } catch {
          findings.append(unreadable("doesn't parse as a crash report: \(error.message)"))
        }
      }
    }
    reports.sort { ($0.report.captureTime, $0.path) < ($1.report.captureTime, $1.path) }

    var unclaimed = reports[...]
    var previous: SimAppState?
    for step in evidence.steps {
      defer { previous = step.appState }
      guard step.appState == .notRunning, previous != .notRunning else { continue }
      let name = "step \(SimStep.stem(step.n)) \"\(step.label)\""
      let gone = "\(name): the app was not running, so it exited or crashed"
      if let claimed = unclaimed.popFirst() {
        findings.append(
          SimEvidenceFinding(
            rule: .appExited, step: step.n, path: claimed.path,
            message: "\(gone); crash report \(claimed.path)\(describe(claimed.report))"))
      } else {
        findings.append(
          SimEvidenceFinding(
            rule: .appExited, step: step.n, path: nil,
            message:
              "\(gone); no crash report for this run is in \(SimSession.directoryName)/\(SimCrashReport.directoryName)/ "
              + "(sim down copies them, and an exit without a crash writes none)"))
      }
    }
    for left in unclaimed {
      findings.append(
        SimEvidenceFinding(
          rule: .appExited, step: nil, path: left.path,
          message: "run \(evidence.runID): the app crashed outside any recorded step; crash report "
            + "\(left.path)\(describe(left.report))"))
    }
    return findings
  }

  private static func describe(_ report: SimCrashReport) -> String {
    report.exception.map { " (\($0))" } ?? ""
  }
}
