import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Testing

@Suite("build halt log")
struct BuildHaltLogTests {
  static let start = Date(timeIntervalSince1970: 1_790_000_000)

  static func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "swiftgate-build-halt-log-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  static func log(_ root: URL, at seconds: Double, id: String) -> BuildHaltLog {
    BuildHaltLog(root: root, now: { start.addingTimeInterval(seconds) }, newEventID: { id })
  }

  @Test(
    "a torn last line from a crashed write doesn't stop a resume of an earlier halt — catches 1 cut write locking every halt open"
  )
  func tornLastLineDoesNotBlockAResume() throws {
    let root = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try Self.log(root, at: 0, id: "halt-1").halt(buildRun: "run-1", task: nil, reason: .budget)
    let file = StateRoot.tree(root).url(RunLayout.eventsFile(.build))
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(#"{"eventID":"cut"#.utf8))
    try handle.close()

    let resume = try Self.log(root, at: 90, id: "resume-1").resume(
      buildRun: "run-1", task: nil, answer: .abandon)

    #expect(resume.parentID == "halt-1")
    #expect(
      resume.payload
        == .buildResume(
          BuildResumeEvent(buildRun: "run-1", task: nil, answer: .abandon, waitMilliseconds: 90_000)
        ))
  }

  @Test(
    "a whole line that doesn't parse stops a resume naming the stream — catches a guess at which halt is open"
  )
  func corruptLineStopsAResume() throws {
    let root = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try Self.log(root, at: 0, id: "halt-1").halt(buildRun: "run-1", task: nil, reason: .stall)
    let file = StateRoot.tree(root).url(RunLayout.eventsFile(.build))
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("not an event\n".utf8))
    try handle.close()

    do {
      _ = try Self.log(root, at: 5, id: "resume-1").resume(
        buildRun: "run-1", task: nil, answer: .retry)
      Issue.record("a resume over a corrupt stream was recorded")
    } catch {
      guard case .unreadable(let path, _) = error else {
        Issue.record("expected unreadable, got \(error)")
        return
      }
      #expect(path == file.path)
    }
    #expect(try Data(contentsOf: file).split(separator: UInt8(ascii: "\n")).count == 2)
  }

  @Test(
    "a halt the stream won't take throws naming the file — catches a lost halt reported as recorded"
  )
  func unwritableStreamThrows() throws {
    let root = Self.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = StateRoot.tree(root).url(RunLayout.eventsFile(.build))
    // A directory where the build stream's file belongs.
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)

    do {
      _ = try Self.log(root, at: 0, id: "halt-1").halt(
        buildRun: "run-1", task: nil, reason: .stall)
      Issue.record("a halt into a directory was recorded")
    } catch {
      guard case .unwritten(let failure) = error else {
        Issue.record("expected unwritten, got \(error)")
        return
      }
      #expect(failure.path.hasSuffix(RunLayout.eventsFile(.build)), "\(failure)")
    }
  }
}
