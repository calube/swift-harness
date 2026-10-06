import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@Suite("view server ensurer")
struct ViewServerEnsurerTests {
  static func commonDirectory() throws -> URL {
    let url = TestTemporaryDirectory.root.appending(
      path: "view-server-\(UUID().uuidString)/.git", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// Stands in for the processes: a launched server saves its record at once, on the port its
  /// `--port` asked for or a fresh one, and answers while its pid is alive.
  final class FakeServers: ViewServerProbing, DetachedLaunching {
    let registry: ViewServerRegistry
    let saves: Bool
    let launches = Mutex<[DetachedLaunch]>([])
    let alive = Mutex<Set<Int32>>([])

    init(registry: ViewServerRegistry, saves: Bool = true) {
      self.registry = registry
      self.saves = saves
    }

    func answers(_ record: ViewServerRecord) async -> Bool {
      alive.withLock { $0.contains(record.pid) }
    }

    func launch(_ request: DetachedLaunch) throws(DetachedLaunchError) -> Int32 {
      let count = launches.withLock {
        $0.append(request)
        return $0.count
      }
      let pid = Int32(9_000 + count)
      alive.withLock { _ = $0.insert(pid) }
      guard saves else { return pid }
      let asked = request.arguments.firstIndex(of: "--port").flatMap {
        Int(request.arguments[request.arguments.index(after: $0)])
      }
      let port = asked.flatMap { $0 == 0 ? nil : $0 } ?? 50_000 + count
      try? registry.write(ViewServerRecord(pid: pid, port: port, startedAt: Date()))
      return pid
    }

    func kill(_ pid: Int32) { alive.withLock { _ = $0.remove(pid) } }
  }

  static func ensurer(_ servers: FakeServers) -> ViewServerEnsurer {
    ViewServerEnsurer(
      registry: servers.registry, probe: servers, launcher: servers, startDeadline: .seconds(1),
      wait: { _ in })
  }

  static func ensure(_ ensurer: ViewServerEnsurer, switchValue: String? = nil) async throws
    -> ViewServerEnsurer.Outcome
  {
    try await ensurer.ensure(
      switchValue: switchValue, executable: "/usr/local/bin/swiftgate",
      serve: ["view", "--detached"], directory: "/tmp")
  }

  @Test(
    "a second ensure gets the same port and pid and launches nothing — catches a new server, and a new URL, on every build start"
  )
  func secondCallReuses() async throws {
    let common = try Self.commonDirectory()
    defer { TestTemporaryDirectory.remove(common.deletingLastPathComponent()) }
    let servers = FakeServers(registry: ViewServerRegistry(commonDirectory: common))
    let ensurer = Self.ensurer(servers)

    guard case .started(let first) = try await Self.ensure(ensurer) else {
      Issue.record("the first call started no server")
      return
    }
    let second = try await Self.ensure(ensurer)

    #expect(second == .reused(first))
    #expect(servers.launches.withLock { $0.count } == 1)
    let launch = try #require(servers.launches.withLock { $0.first })
    #expect(launch.arguments.starts(with: ["view", "--detached"]))
    #expect(launch.workingDirectory == "/tmp")
    #expect(launch.logPath == servers.registry.log.path)
  }

  @Test(
    "a saved server that stopped answering is started again on its saved port — catches a dashboard URL that changes after the idle exit"
  )
  func deadServerRestartsOnItsPort() async throws {
    let common = try Self.commonDirectory()
    defer { TestTemporaryDirectory.remove(common.deletingLastPathComponent()) }
    let servers = FakeServers(registry: ViewServerRegistry(commonDirectory: common))
    let ensurer = Self.ensurer(servers)
    guard case .started(let first) = try await Self.ensure(ensurer) else {
      Issue.record("the first call started no server")
      return
    }
    servers.kill(first.pid)

    guard case .started(let again) = try await Self.ensure(ensurer) else {
      Issue.record("a dead server was reused")
      return
    }
    #expect(again.port == first.port)
    #expect(again.pid != first.pid)
    let arguments = try #require(servers.launches.withLock { $0.last?.arguments })
    #expect(arguments.suffix(2) == ["--port", "\(first.port)"])
  }

  @Test(
    "SWIFTGATE_VIEW=off launches nothing, writes no record and reuses nothing — catches a server started on a machine that turned the viewer off"
  )
  func offStartsNothing() async throws {
    let common = try Self.commonDirectory()
    defer { TestTemporaryDirectory.remove(common.deletingLastPathComponent()) }
    let servers = FakeServers(registry: ViewServerRegistry(commonDirectory: common))
    #expect(try await Self.ensure(Self.ensurer(servers), switchValue: "off") == .off)
    #expect(servers.launches.withLock { $0.isEmpty })
    #expect(servers.registry.read() == nil)
    #expect(!FileManager.default.fileExists(atPath: servers.registry.file.path))
  }

  @Test(
    "a started server that never saves its record fails the ensure naming its log, after the deadline — catches an ensure that hangs or prints a URL nothing serves"
  )
  func unsavedRecordFails() async throws {
    let common = try Self.commonDirectory()
    defer { TestTemporaryDirectory.remove(common.deletingLastPathComponent()) }
    let servers = FakeServers(registry: ViewServerRegistry(commonDirectory: common), saves: false)
    let waited = Mutex(Duration.zero)
    let ensurer = ViewServerEnsurer(
      registry: servers.registry, probe: servers, launcher: servers, startDeadline: .seconds(2),
      wait: { step in waited.withLock { $0 += step } })
    await #expect(throws: ViewServerEnsurer.Failure.self) {
      try await Self.ensure(ensurer)
    }
    do {
      _ = try await Self.ensure(ensurer)
    } catch {
      #expect("\(error)".contains(ViewServerRecord.logName))
    }
    #expect(waited.withLock { $0 } >= .seconds(2))
  }

  @Test(
    "the registry reads back what it wrote and reads a torn record as none — catches an ensure that crashes on a half-written file"
  )
  func registryRoundTrip() throws {
    let common = try Self.commonDirectory()
    defer { TestTemporaryDirectory.remove(common.deletingLastPathComponent()) }
    let registry = ViewServerRegistry(commonDirectory: common)
    #expect(registry.read() == nil)
    let record = ViewServerRecord(
      pid: 77, port: 52_000, startedAt: Date(timeIntervalSince1970: 1_791_000_000))
    try registry.write(record)
    #expect(registry.read() == record)
    try Data("{\"pid\":".utf8).write(to: registry.file)
    #expect(registry.read() == nil)
  }

  @Test(
    "a report folder is final once its page is written from a done run's view, not from a snapshot or a running run — catches /final serving a mid-run snapshot"
  )
  func reportFolderFinal() throws {
    let common = try Self.commonDirectory()
    defer { TestTemporaryDirectory.remove(common.deletingLastPathComponent()) }
    let folder = RunReportFolder(directory: common.appending(path: "reports/run"))
    #expect(!folder.isFinal)
    func write(state: String, snapshotAt: String?) throws {
      let snapshot = snapshotAt.map { "\"\($0)\"" } ?? "null"
      try folder.write(
        page: Data("<html></html>".utf8),
        view: Data("{\"run\":{\"state\":\"\(state)\",\"snapshotAt\":\(snapshot)}}".utf8),
        carrying: .init(carried: [], left: []), from: [common])
    }
    try write(state: "running", snapshotAt: "2026-10-04T05:00:00Z")
    #expect(!folder.isFinal)
    try write(state: "done", snapshotAt: "2026-10-04T05:00:00Z")
    #expect(!folder.isFinal)
    try write(state: "done", snapshotAt: nil)
    #expect(folder.isFinal)
    try FileManager.default.removeItem(at: folder.directory.appending(path: "index.html"))
    #expect(!folder.isFinal)
  }

  @Test(
    "shutdown signals the saved server only while it answers as itself and returns its record, and leaves a dead or missing one alone — catches a viewer outliving its run, or a signal sent to a pid the server no longer holds"
  )
  func shutdownStopsOnlyAnAnsweringServer() async throws {
    let common = try Self.commonDirectory()
    defer { TestTemporaryDirectory.remove(common.deletingLastPathComponent()) }
    let registry = ViewServerRegistry(commonDirectory: common)
    let servers = FakeServers(registry: registry)
    let signalled = Mutex<[Int32]>([])
    let shutdown = ViewServerShutdown(
      registry: registry, probe: servers,
      signal: { pid in
        signalled.withLock { $0.append(pid) }
        servers.kill(pid)
        return true
      })
    #expect(await shutdown.stop() == nil, "no saved server")

    let started = try await Self.ensure(Self.ensurer(servers))
    guard case .started(let record) = started else {
      Issue.record("no server started: \(started)")
      return
    }

    #expect(await shutdown.stop() == record)
    #expect(signalled.withLock { $0 } == [record.pid])
    #expect(await shutdown.stop() == nil, "a stopped server isn't signalled again")
    #expect(signalled.withLock { $0 } == [record.pid])
  }

  @Test(
    "a report carries send-money-4's flow steps and batch log with every screenshot path relative to the run and every other machine path cut to its last component — catches a published report holding the machine's home folder"
  )
  func reportEvidenceJSONHasNoMachinePaths() throws {
    let common = try Self.commonDirectory()
    defer { TestTemporaryDirectory.remove(common.deletingLastPathComponent()) }
    let runs = common.appending(path: "runs", directoryHint: .isDirectory)
    let runID = "20261005T061244Z-0883dbbe"
    let flow = "\(runID)/qa/01-req-contact-search.flow"
    for name in ["steps.json", "batch.json"] {
      let target = runs.appending(path: "\(flow)/\(name)")
      try FileManager.default.createDirectory(
        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Fixture.data("RunView/send-money-4-evidence/\(flow)/\(name)").write(to: target)
    }
    let folder = RunReportFolder(directory: common.appending(path: "reports/run"))

    try folder.write(
      page: Data("<html></html>".utf8), view: Data("{}".utf8),
      carrying: .init(carried: ["\(flow)/steps.json", "\(flow)/batch.json"], left: []),
      from: [runs])

    var strings: [String] = []
    func collect(_ value: Any) {
      if let text = value as? String { strings.append(text) }
      if let object = value as? [String: Any] { object.values.forEach(collect) }
      if let array = value as? [Any] { array.forEach(collect) }
    }
    for name in ["steps.json", "batch.json"] {
      let copy = folder.directory.appending(path: "runs/\(flow)/\(name)")
      collect(try JSONSerialization.jsonObject(with: Data(contentsOf: copy)))
    }
    #expect(!strings.isEmpty)
    #expect(
      !strings.contains {
        $0.hasPrefix("/") || $0.hasPrefix("~") || $0.contains("/TRIAL/") || $0.contains("/HOME/")
      })
    let shot = "qa/01-req-contact-search.flow/sim/steps/.3865-C3C9E47B.png"
    #expect(strings.contains(shot))
    #expect(strings.contains("Saved screenshot: \(shot)"))
    #expect(strings.contains("swiftgate-\(runID)-row1"))
    #expect(strings.contains("com.example.TimedBuildStarter"))
  }
}
