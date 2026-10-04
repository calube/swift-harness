import CryptoKit
import Foundation
import Synchronization

/// `swiftgate discover`'s pure core: every reader's areas, CI commands over guesses, the
/// orchestrator's edits, and the config an applied proposal writes.
public enum Discover {
  /// `[brownfield] slice_budget_s` for a clone discovered for the first time.
  public static let defaultSliceBudgetSeconds = 30

  /// `[build.presets.brownfield]` for a clone discovered for the first time (design §13).
  public static let brownfieldPreset = BuildPreset(
    designTier: .none, maxParallel: 3, review: .classified, taskGate: .tier(.slice),
    mergeGate: .merge, workerModel: .claudeSonnet55, timeBudgetMin: 0, stopStartsBeforeMin: 0,
    onDesignConflict: .block, taskProof: .prove, stallMin: 2)

  /// `[judge]` for a clone discovered for the first time: the owned profile's default backend and
  /// thresholds, so `judge diff-risk` can rate a slice (design §11.5) without a hand edit. Claude
  /// sends nothing to a third party; Jev stays opt-in (ADR 0007).
  public static let defaultJudge = JudgeConfig.enabled(
    backend: .claude, thresholds: .defaults, model: nil)

  /// Runs every reader over `tree`, then lets the commands CI, `Makefile`, `justfile` and `bin/*`
  /// already run replace a reader's guess or fill a missing step.
  public static func propose(
    tree: TrackedTreeSnapshot, head: String, dirty: [String],
    readers: [any EcosystemReader] = EcosystemReaders.all
  ) -> DiscoverProposal {
    let areas = distinctNames(readers.flatMap { $0.areas(in: tree) })
    let mined = CICommandMining.commands(in: tree, areas: areas)
    return DiscoverProposal(
      head: head,
      areas: CICommandMining.outrank(areas, with: mined).map {
        TestReportRequests.requesting($0, in: tree)
      },
      dirty: dirty)
  }

  /// ``propose(tree:head:dirty:readers:)``, naming every file a reader or the miner read. Readers
  /// see nothing but the listing and those files, so the 2 together decide the proposal.
  public static func proposeRecordingInputs(
    tree: TrackedTreeSnapshot, head: String, dirty: [String],
    readers: [any EcosystemReader] = EcosystemReaders.all
  ) -> (proposal: DiscoverProposal, inputs: [String]) {
    let read = Mutex<Set<String>>([])
    let recording = TrackedTreeSnapshot(
      paths: tree.paths,
      read: { path in
        read.withLock { _ = $0.insert(path) }
        return tree.read(path)
      })
    let proposal = propose(tree: recording, head: head, dirty: dirty, readers: readers)
    return (proposal, read.withLock { $0.sorted() })
  }

  /// The key a cached proposal is reused under: the whole listing, so any added, removed or
  /// renamed file misses, and the bytes of each input, so an edited build file misses. `salt`
  /// names the discover build and its readers, whose logic the key can't see.
  public static func cacheKey(tree: TrackedTreeSnapshot, inputs: [String], salt: String)
    -> String
  {
    var hasher = SHA256()
    hasher.update(data: Data("\(salt)\0".utf8))
    for path in tree.paths { hasher.update(data: Data("\(path)\n".utf8)) }
    hasher.update(data: Data("\0".utf8))
    for path in inputs.sorted() {
      let digest = tree.read(path).map {
        SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
      }
      hasher.update(data: Data("\(path)\0\(digest ?? "-")\n".utf8))
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// `config.toml` rejects 2 areas with 1 name, so a later duplicate takes its kind, then a
  /// number, as a suffix.
  private static func distinctNames(_ areas: [ProposedArea]) -> [ProposedArea] {
    var taken: Set<String> = []
    return areas.map { area in
      var name = area.name
      if taken.contains(name) { name = "\(area.name)-\(area.kind.rawValue)" }
      var counter = 2
      while taken.contains(name) {
        name = "\(area.name)-\(counter)"
        counter += 1
      }
      taken.insert(name)
      return name == area.name ? area : area.renamed(name)
    }
  }

  /// Applies `carried` (edits a previous `--apply` recorded) and then `new`, where a new edit
  /// replaces a carried one for the same area and step. A new edit naming an unknown area fails;
  /// a carried one whose area is gone comes back in ``DiscoverEditResult/stale``.
  public static func applying(
    carried: [DiscoverEdit], new: [DiscoverEdit], to proposal: DiscoverProposal
  ) throws(DiscoverEditError) -> DiscoverEditResult {
    let names = Set(proposal.areas.map(\.name))
    if let unknown = new.first(where: { !names.contains($0.area) }) {
      throw .unknownArea(unknown.area)
    }
    let replaced = Set(new.map(\.target))
    let kept = carried.filter { !replaced.contains($0.target) }
    let stale = kept.filter { !names.contains($0.area) }
    let applied = kept.filter { names.contains($0.area) } + new
    let areas = proposal.areas.map { area in
      applied.filter { $0.area == area.name }.reduce(area) { $0.applying($1) }
    }
    return DiscoverEditResult(
      proposal: DiscoverProposal(head: proposal.head, areas: areas, dirty: proposal.dirty),
      applied: applied, stale: stale)
  }

  /// The config an applied `proposal` writes. Settings, `[[allow]]` entries, presets and `[judge]`
  /// come from `existing` when there is one, so a rediscovery keeps them; areas always come from
  /// the proposal.
  public static func config(from proposal: DiscoverProposal, keeping existing: BrownfieldConfig?)
    -> BrownfieldConfig
  {
    let settings = existing?.brownfield
    return BrownfieldConfig(
      brownfield: BrownfieldSettings(
        discoveredAt: proposal.head,
        sliceBudgetSeconds: settings?.sliceBudgetSeconds ?? defaultSliceBudgetSeconds,
        timeBudgetMinutes: settings?.timeBudgetMinutes ?? 0, sensitive: settings?.sensitive ?? []),
      areas: proposal.areas.map(BrownfieldArea.init(proposed:)), allow: existing?.allow ?? [],
      buildPresets: existing?.buildPresets ?? ["brownfield": brownfieldPreset],
      judge: existing?.judge ?? defaultJudge)
  }
}

/// 1 `--set <area>.<step>=<command>` or `--drop <area>.<step>`.
public struct DiscoverEdit: Sendable, Equatable, Codable {
  public enum Change: Sendable, Equatable {
    case set(command: String)
    case drop(reason: String)
  }

  /// The source a set value shows in the table and in `last.json`.
  public static let orchestratorSource = "discover --apply --set"

  public let area: String
  public let step: AreaStep
  public let change: Change

  public init(area: String, step: AreaStep, change: Change) {
    self.area = area
    self.step = step
    self.change = change
  }

  /// Parses the command line's `--set`, `--drop` and `--reason` values. Every drop needs the
  /// reason; 1 area and step can't be both set and dropped.
  public static func parse(sets: [String], drops: [String], reason: String?)
    throws(DiscoverEditError) -> [DiscoverEdit]
  {
    var edits: [DiscoverEdit] = []
    for value in sets {
      guard let equals = value.firstIndex(of: "=") else { throw .malformedSet(value) }
      let command = String(value[value.index(after: equals)...])
      guard !command.trimmingCharacters(in: .whitespaces).isEmpty,
        let (area, step) = try target(String(value[..<equals]))
      else { throw .malformedSet(value) }
      edits.append(DiscoverEdit(area: area, step: step, change: .set(command: command)))
    }
    if !drops.isEmpty {
      guard let reason, !reason.trimmingCharacters(in: .whitespaces).isEmpty else {
        throw .dropNeedsReason
      }
      for value in drops {
        guard let (area, step) = try target(value) else { throw .malformedDrop(value) }
        edits.append(DiscoverEdit(area: area, step: step, change: .drop(reason: reason)))
      }
    }
    var seen: Set<String> = []
    for edit in edits where !seen.insert(edit.target).inserted {
      throw .conflicting(edit.target)
    }
    return edits
  }

  /// `<area>.<step>`, split at the last dot, since a step never holds one; `nil` when either half
  /// is empty.
  private static func target(_ text: String) throws(DiscoverEditError) -> (String, AreaStep)? {
    guard let dot = text.lastIndex(of: ".") else { return nil }
    let area = String(text[..<dot])
    let rawStep = String(text[text.index(after: dot)...])
    guard !area.isEmpty, !rawStep.isEmpty else { return nil }
    guard let step = AreaStep(rawValue: rawStep) else { throw .unknownStep(rawStep) }
    guard AreaStep.settable.contains(step) else { throw .stepHasNoKey(step) }
    return (area, step)
  }

  /// `<area>.<step>`, as the command line spells it.
  var target: String { "\(area).\(step.rawValue)" }

  private enum CodingKeys: String, CodingKey {
    case area, step, set, drop
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    area = try container.decode(String.self, forKey: .area)
    step = try container.decode(AreaStep.self, forKey: .step)
    let command = try container.decodeIfPresent(String.self, forKey: .set)
    let reason = try container.decodeIfPresent(String.self, forKey: .drop)
    switch (command, reason) {
    case (let command?, nil): change = .set(command: command)
    case (nil, let reason?): change = .drop(reason: reason)
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .set, in: container, debugDescription: "exactly 1 of set and drop")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(area, forKey: .area)
    try container.encode(step, forKey: .step)
    switch change {
    case .set(let command): try container.encode(command, forKey: .set)
    case .drop(let reason): try container.encode(reason, forKey: .drop)
    }
  }
}

/// A proposal with the orchestrator's edits applied.
public struct DiscoverEditResult: Sendable, Equatable {
  public let proposal: DiscoverProposal
  /// Every edit the proposal now carries, carried and new; `discover.run`'s `edited` counts them.
  public let applied: [DiscoverEdit]
  /// Carried edits whose area this proposal no longer has.
  public let stale: [DiscoverEdit]

  public init(proposal: DiscoverProposal, applied: [DiscoverEdit], stale: [DiscoverEdit]) {
    self.proposal = proposal
    self.applied = applied
    self.stale = stale
  }
}

public enum DiscoverEditError: Error, Sendable, Equatable {
  /// A `--set` value that isn't `<area>.<step>=<command>`.
  case malformedSet(String)
  /// A `--drop` value that isn't `<area>.<step>`.
  case malformedDrop(String)
  case unknownStep(String)
  /// `generate` comes from the area's inclusion and has no config key.
  case stepHasNoKey(AreaStep)
  case dropNeedsReason
  /// `<area>.<step>` given to both `--set` and `--drop`, or twice.
  case conflicting(String)
  case unknownArea(String)

  public var message: String {
    switch self {
    case .malformedSet(let value): "--set \(value): expected <area>.<step>=<command>"
    case .malformedDrop(let value): "--drop \(value): expected <area>.<step>"
    case .unknownStep(let value):
      "\(value): unknown step; expected one of \(AreaStep.settable.map(\.rawValue).joined(separator: ", "))"
    case .stepHasNoKey(let step):
      "\(step.rawValue) comes from the area's inclusion and can't be set"
    case .dropNeedsReason: "--drop needs --reason"
    case .conflicting(let target): "\(target) is edited more than once"
    case .unknownArea(let area): "no area named \(area) in this proposal"
    }
  }
}

extension AreaStep {
  /// The steps `config.toml` has a key for, which `--set` and `--drop` accept.
  public static let settable: [AreaStep] = [.test, .testFiles, .lint, .build, .e2e]
}

extension ProposedArea {
  func renamed(_ name: String) -> ProposedArea {
    ProposedArea(
      name: name, root: root, language: language, kind: kind, source: source,
      commands: commands, missing: missing, testGlobs: testGlobs, xcode: xcode,
      generatedProjectTracked: generatedProjectTracked)
  }

  func replacing(commands: [AreaStep: Sourced<String>], missing: [AreaStep: String])
    -> ProposedArea
  {
    ProposedArea(
      name: name, root: root, language: language, kind: kind, source: source,
      commands: commands, missing: missing, testGlobs: testGlobs, xcode: xcode,
      generatedProjectTracked: generatedProjectTracked)
  }

  fileprivate func applying(_ edit: DiscoverEdit) -> ProposedArea {
    var commands = self.commands
    var missing = self.missing
    switch edit.change {
    case .set(let command):
      commands[edit.step] = Sourced(
        value: command, source: DiscoverEdit.orchestratorSource, confidence: .orchestrator)
      missing[edit.step] = nil
    case .drop(let reason):
      commands[edit.step] = nil
      missing[edit.step] = reason
    }
    return replacing(commands: commands, missing: missing)
  }
}
