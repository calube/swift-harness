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
  /// ``SimCrashReport/belongs(to:)`` the run. Only reports modified since `startedAt` are read,
  /// since macOS writes a report after its crash, and only those naming the run's device are
  /// parsed, so another process's report, in whatever shape, is no note.
  public func collect(for session: SimSession, into simDirectory: URL) -> SimCrashCollection {
    let manager = FileManager.default
    let candidates: [URL]
    do {
      candidates = try manager.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
    } catch {
      return SimCrashCollection(
        copied: [],
        notes: [
          "crash reports not collected: can't list \(directory.path): \(error.localizedDescription)"
        ])
    }
    var copied: [String] = []
    var notes: [String] = []
    let destination = simDirectory.appending(
      path: SimCrashReport.directoryName, directoryHint: .isDirectory)
    for file in candidates.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    where file.pathExtension == SimCrashReport.fileExtension {
      let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate
      if let modified, modified < session.startedAt { continue }
      let data: Data
      let report: SimCrashReport
      do {
        data = try Data(contentsOf: file)
      } catch {
        notes.append("crash report \(file.path) can't be read: \(error.localizedDescription)")
        continue
      }
      guard data.range(of: Data(session.udid.utf8)) != nil else { continue }
      do throws(SimCrashReportError) {
        report = try SimCrashReport.parse(data)
      } catch {
        notes.append("\(file.path) skipped: \(error.message)")
        continue
      }
      guard report.belongs(to: session) else { continue }
      let name = file.lastPathComponent
      do {
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        try data.write(to: destination.appending(path: name), options: .atomic)
        copied.append(SimCrashReport.path(fileName: name))
      } catch {
        notes.append(
          "crash report \(file.path) not copied into \(destination.path): "
            + error.localizedDescription)
      }
    }
    return SimCrashCollection(copied: copied, notes: notes)
  }
}
