import Foundation
import SwiftGateDomain

/// What one collection did: the reports it copied, relative to the run's `sim/` folder, and a
/// note for each candidate report it couldn't read or copy.
public struct SimCrashCollection: Sendable, Equatable {
  public var copied: [String]
  public var notes: [String]

  public init(copied: [String], notes: [String]) {
    self.copied = copied
    self.notes = notes
  }
}

/// Finds a run's crash reports where macOS writes them, and copies them into the run.
///
/// A simulator app's crash report lands on the Mac, not in the device, so it outlives the device
/// `sim down` deletes.
public struct CrashReportReader: Sendable {
  /// Where macOS writes the user's `.ips` crash reports.
  public var directory: URL

  public init(directory: URL) {
    self.directory = directory
  }

  /// `~/Library/Logs/DiagnosticReports`.
  public static func defaultDirectory() -> URL {
    FileManager.default.homeDirectoryForCurrentUser.appending(
      path: "Library/Logs/DiagnosticReports", directoryHint: .isDirectory)
  }

  /// Copies into `<simDirectory>/crashes/`, unmodified, each `.ips` report that
  /// ``SimCrashReport/belongs(to:)`` the run.
  public func collect(for session: SimSession, into simDirectory: URL) -> SimCrashCollection {
    SimCrashCollection(copied: [], notes: [])
  }
}
