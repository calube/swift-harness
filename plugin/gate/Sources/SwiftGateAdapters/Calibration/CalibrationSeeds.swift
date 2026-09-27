import Foundation
import SwiftGateDomain

/// A case's `label.json` in one calibration suite: what a correct agent does with the case.
public protocol CalibrationSeedLabel: Sendable, Equatable {
  static var suite: CalibrationSuite { get }
  /// Decodes and validates a label for `agent`'s case.
  static func decode(_ data: Data, agent: String) -> Result<Self, CalibrationLabel.SeedError>
  /// Case entries, besides `input.md` and `label.json`, that `agent`'s cases must hold.
  static func requiredEntries(agent: String) -> [String]
}

/// The seeds under a suite's seeds directory: one directory per agent, named after its
/// `agents/<agent>.md`, holding one directory per case.
public struct CalibrationSeeds<Label: CalibrationSeedLabel>: Sendable, Equatable {
  public struct Case: Sendable, Equatable {
    public let name: String
    /// Repo-relative case directory.
    public let directory: String
    public let input: String
    public let label: Label
  }

  public struct Agent: Sendable, Equatable {
    public let name: String
    /// The agent file's body after its frontmatter: what the agent runs with.
    public let systemPrompt: String
    /// The frontmatter's `model`, when it pins one.
    public let model: String?
    /// The frontmatter's `tools`, as written.
    public let tools: String?
    public let cases: [Case]
  }

  /// A seed-set defect; `path` is repo-relative. Every one is a fix to the repository, never an
  /// environment problem.
  public enum Problem: Sendable, Equatable {
    case noSeeds(path: String)
    case missingLabel(path: String)
    case missingInput(path: String)
    /// A file or directory the agent's cases need besides `input.md`; `path` is the entry.
    case missingEntry(path: String)
    case invalidLabel(path: String, reason: String)
    /// A seed directory with no `agents/<name>.md`, or not one of the suite's agents.
    case unknownAgent(path: String)
    /// A hashed agent with no case.
    case uncalibratedAgent(path: String)
    case unreadable(path: String, reason: String)
  }

  public let agents: [Agent]
  public let problems: [Problem]

  public static func load(root: URL) -> CalibrationSeeds {
    let suite = Label.suite
    let fileManager = FileManager.default
    let seedsRoot = suite.seedsDirectory
    var problems: [Problem] = []
    var agents: [Agent] = []
    // Agents with at least one case directory, labelled or not: a broken case is reported as
    // itself, not also as an uncalibrated agent.
    var seeded: Set<String> = []

    func directories(_ path: String) -> [String]? {
      let url = root.appending(path: path, directoryHint: .isDirectory)
      do {
        return try fileManager.contentsOfDirectory(atPath: url.path).filter { name in
          var isDirectory: ObjCBool = false
          return !name.hasPrefix(".")
            && fileManager.fileExists(
              atPath: url.appending(path: name).path, isDirectory: &isDirectory)
            && isDirectory.boolValue
        }.sorted()
      } catch {
        problems.append(.unreadable(path: path, reason: "\(error)"))
        return nil
      }
    }

    func text(_ path: String) -> String? {
      do {
        return try String(contentsOf: root.appending(path: path), encoding: .utf8)
      } catch {
        problems.append(.unreadable(path: path, reason: "\(error)"))
        return nil
      }
    }

    func exists(_ path: String) -> Bool {
      fileManager.fileExists(atPath: root.appending(path: path).path)
    }

    let agentNames = exists(seedsRoot) ? (directories(seedsRoot) ?? []) : []
    for agentName in agentNames {
      let agentSeeds = "\(seedsRoot)/\(agentName)"
      let agentFile = "\(CalibrationSuite.agentsDirectory)/\(agentName).md"
      guard suite.isHashed(agentFile), exists(agentFile) else {
        problems.append(.unknownAgent(path: agentSeeds))
        continue
      }
      guard let agentText = text(agentFile), let caseNames = directories(agentSeeds) else {
        continue
      }
      if !caseNames.isEmpty { seeded.insert(agentName) }
      var cases: [Case] = []
      for caseName in caseNames {
        let directory = "\(agentSeeds)/\(caseName)"
        let inputPath = "\(directory)/\(CalibrationSuite.inputFile)"
        let labelPath = "\(directory)/\(CalibrationSuite.labelFile)"
        guard exists(labelPath) else {
          problems.append(.missingLabel(path: directory))
          continue
        }
        guard exists(inputPath) else {
          problems.append(.missingInput(path: directory))
          continue
        }
        if let missing = Label.requiredEntries(agent: agentName).first(where: {
          !exists("\(directory)/\($0)")
        }) {
          problems.append(.missingEntry(path: "\(directory)/\(missing)"))
          continue
        }
        guard let input = text(inputPath), let labelText = text(labelPath) else { continue }
        switch Label.decode(Data(labelText.utf8), agent: agentName) {
        case .failure(let error):
          problems.append(.invalidLabel(path: labelPath, reason: error.message))
        case .success(let label):
          cases.append(Case(name: caseName, directory: directory, input: input, label: label))
        }
      }
      agents.append(
        Agent(
          name: agentName, systemPrompt: body(ofAgent: agentText),
          model: frontmatterValue("model", ofAgent: agentText),
          tools: frontmatterValue("tools", ofAgent: agentText), cases: cases))
    }

    if let hashed = try? CalibrationHash.discover(root: root, suite: suite) {
      for file in hashed where suite.isHashedAgent(file.path) {
        let name = String(
          file.path.dropFirst(CalibrationSuite.agentsDirectory.count + 1).dropLast(".md".count))
        if !seeded.contains(name) {
          problems.append(.uncalibratedAgent(path: file.path))
        }
      }
    } else {
      problems.append(
        .unreadable(
          path: CalibrationSuite.agentsDirectory,
          reason: "can't list the \(suite.rawValue) agents"))
    }
    if agents.allSatisfy(\.cases.isEmpty), problems.isEmpty {
      problems.append(.noSeeds(path: seedsRoot))
    }
    return CalibrationSeeds(agents: agents, problems: problems)
  }

  /// Strips a leading `---` frontmatter block, then surrounding blank lines.
  static func body(ofAgent text: String) -> String {
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    var body = Substring(normalized)
    if let frontmatter = frontmatterRange(normalized) {
      body = normalized[frontmatter.upperBound...]
    }
    return body.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// A top-level `key: value` line of the frontmatter, trimmed; `nil` when absent or empty.
  static func frontmatterValue(_ key: String, ofAgent text: String) -> String? {
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    guard let frontmatter = frontmatterRange(normalized) else { return nil }
    for line in normalized[..<frontmatter.lowerBound].split(separator: "\n")
    where line.hasPrefix("\(key):") {
      let value = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
      return value.isEmpty ? nil : value
    }
    return nil
  }

  /// The closing `\n---\n` of a leading frontmatter block.
  private static func frontmatterRange(_ normalized: String) -> Range<String.Index>? {
    guard normalized.hasPrefix("---\n") else { return nil }
    return normalized.range(
      of: "\n---\n",
      range: normalized.index(normalized.startIndex, offsetBy: 3)..<normalized.endIndex)
  }
}
