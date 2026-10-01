import Foundation
import SwiftGateDomain

/// Reads every build run's task returns, its plan's ledger write sets and its `events.jsonl` from
/// the plans' shared state under the git common dir, read only. A file that doesn't read is
/// listed as damage and the rest of its run is still read.
public struct BuildJoinReader: Sendable {
  /// The git common dir, absolute.
  public let commonDirectory: URL

  public init(commonDirectory: URL) {
    self.commonDirectory = commonDirectory
  }

  /// The plans directory, relative to the git common dir.
  public static let plansDirectory = "swift-harness/plans"

  /// Every build run of every plan, or only `buildRunID` when given.
  public func read(buildRunID: String?) -> BuildJoin {
    var damage: [BuildJoinDamage] = []
    var runs: [BuildJoin.Run] = []
    let plans = directories(in: Self.plansDirectory, damage: &damage)
      .filter { $0 != PlanStateLayout.sprintsDirectoryName }
    for plan in plans {
      let planPath = "\(Self.plansDirectory)/\(plan)"
      let runIDs = directories(in: "\(planPath)/build", damage: &damage)
        .filter { buildRunID == nil || $0 == buildRunID }
      guard !runIDs.isEmpty else { continue }
      let writeSets = ledgerWriteSets(planPath, damage: &damage)
      for runID in runIDs {
        runs.append(
          readRun(plan: plan, runID: runID, writeSets: writeSets, damage: &damage))
      }
    }
    if let buildRunID, runs.isEmpty {
      damage.append(
        BuildJoinDamage(
          path: Self.plansDirectory, reason: "no plan holds build run \(buildRunID)"))
    }
    return BuildJoin(source: Self.plansDirectory, runs: runs, damage: damage)
  }

  private func readRun(
    plan: String, runID: String, writeSets: [String: [String]], damage: inout [BuildJoinDamage]
  ) -> BuildJoin.Run {
    let runPath = "\(Self.plansDirectory)/\(plan)/build/\(runID)"
    var returns: [String: TaskReturn] = [:]
    for name in files(in: "\(runPath)/returns", damage: &damage) where name.hasSuffix(".json") {
      let path = "\(runPath)/returns/\(name)"
      guard let data = read(path, damage: &damage) else { continue }
      do {
        let taskReturn = try TaskReturnJSON.decode(data)
        returns[taskReturn.task] = taskReturn
      } catch {
        damage.append(BuildJoinDamage(path: path, reason: "undecodable return: \(error)"))
      }
    }
    var events: [BuildEvent] = []
    let logPath = "\(runPath)/events.jsonl"
    if let data = read(logPath, damage: &damage) {
      let log = BuildEventJSON.decode(data)
      events = log.events
      for entry in log.damage {
        switch entry {
        case .tornLastLine(let line):
          damage.append(BuildJoinDamage(path: "\(logPath):\(line)", reason: "torn last line"))
        case .undecodableLine(let line, let reason):
          damage.append(
            BuildJoinDamage(path: "\(logPath):\(line)", reason: "undecodable line: \(reason)"))
        }
      }
    } else {
      damage.append(BuildJoinDamage(path: logPath, reason: "missing build log"))
    }
    return BuildJoin.Run(
      plan: plan, runID: runID, writeSets: writeSets, returns: returns, events: events)
  }

  private func ledgerWriteSets(
    _ planPath: String, damage: inout [BuildJoinDamage]
  ) -> [String: [String]] {
    let path = "\(planPath)/ledger.json"
    guard let data = read(path, damage: &damage) else {
      damage.append(BuildJoinDamage(path: path, reason: "missing ledger"))
      return [:]
    }
    do {
      let ledger = try LedgerJSON.decode(data)
      return Dictionary(ledger.tasks.map { ($0.id, $0.writeSet) }) { first, _ in first }
    } catch {
      damage.append(BuildJoinDamage(path: path, reason: "undecodable ledger: \(error)"))
      return [:]
    }
  }

  /// The file's bytes; `nil` when it doesn't exist, and damage when it doesn't read.
  private func read(_ path: String, damage: inout [BuildJoinDamage]) -> Data? {
    do {
      return try Data(contentsOf: commonDirectory.appending(path: path))
    } catch CocoaError.fileReadNoSuchFile {
      return nil
    } catch {
      damage.append(BuildJoinDamage(path: path, reason: error.localizedDescription))
      return nil
    }
  }

  private func directories(in path: String, damage: inout [BuildJoinDamage]) -> [String] {
    entries(in: path, damage: &damage).filter(\.isDirectory).map(\.name)
  }

  private func files(in path: String, damage: inout [BuildJoinDamage]) -> [String] {
    entries(in: path, damage: &damage).filter { !$0.isDirectory }.map(\.name)
  }

  /// The names in a directory, sorted; none when it doesn't exist.
  private func entries(
    in path: String, damage: inout [BuildJoinDamage]
  ) -> [(name: String, isDirectory: Bool)] {
    let url = commonDirectory.appending(path: path, directoryHint: .isDirectory)
    do {
      return try FileManager.default.contentsOfDirectory(
        at: url, includingPropertiesForKeys: [.isDirectoryKey]
      )
      .map {
        (
          $0.lastPathComponent,
          (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        )
      }
      .sorted { $0.name < $1.name }
    } catch CocoaError.fileReadNoSuchFile {
      return []
    } catch {
      damage.append(BuildJoinDamage(path: path, reason: error.localizedDescription))
      return []
    }
  }
}
