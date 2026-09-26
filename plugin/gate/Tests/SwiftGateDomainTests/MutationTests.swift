import Foundation
import SwiftGateDomain
import Testing

@Suite("mutants")
struct MutantTests {
  private static let source = """
    func f(_ a: Int) -> Bool {
      if a < 3 {
        return true
      }
      return false
    }

    """

  @Test(
    "a mutant is located by its UTF-8 offset and renders its line before and after — catches a report naming the wrong line"
  )
  func locatesAndRendersDiff() throws {
    let offset = try #require(Self.source.utf8Offset(of: "<"))
    let mutant = try #require(
      Mutant(
        file: "Core/F.swift", text: Self.source, utf8Offset: offset, original: "<",
        replacement: "<=", operator: .relationalBoundary))

    #expect(mutant.line == 2)
    #expect(mutant.column == 8)
    #expect(mutant.diff == "-  if a < 3 {\n+  if a <= 3 {")
    #expect(mutant.apply(to: Self.source)?.contains("if a <= 3 {") == true)
  }

  @Test(
    "a mutant whose original does not match the text at its offset is rejected, and does not apply to changed text — catches mutating the wrong bytes in a file that moved"
  )
  func rejectsMismatch() throws {
    let offset = try #require(Self.source.utf8Offset(of: "<"))
    #expect(
      Mutant(
        file: "F.swift", text: Self.source, utf8Offset: offset, original: ">",
        replacement: ">=", operator: .relationalBoundary) == nil)
    let mutant = try #require(
      Mutant(
        file: "F.swift", text: Self.source, utf8Offset: offset, original: "<",
        replacement: "<=", operator: .relationalBoundary))
    #expect(mutant.apply(to: "func f() {}\n") == nil)
  }

  @Test(
    "a deletion spanning lines renders every original line and the lines left behind — catches a report hiding what a removal took out"
  )
  func multiLineDiff() throws {
    let text = "a()\nfoo(\n  1)\nb()\n"
    let offset = try #require(text.utf8Offset(of: "foo("))
    let mutant = try #require(
      Mutant(
        file: "F.swift", text: text, utf8Offset: offset, original: "foo(\n  1)", replacement: "",
        operator: .removeCall))
    #expect(mutant.line == 2)
    #expect(mutant.diff == "-foo(\n-  1)\n+")
  }
}

@Suite("mutant sampling")
struct MutantSamplingTests {
  private static func mutants(_ count: Int) -> [Mutant] {
    let text = String(repeating: "x < y\n", count: count)
    return (0..<count).compactMap { index in
      Mutant(
        file: "F.swift", text: text, utf8Offset: index * 6 + 2, original: "<", replacement: "<=",
        operator: .relationalBoundary)
    }
  }

  @Test(
    "within the cap every mutant is kept in source order — catches sampling dropping mutants it had room for"
  )
  func underCap() {
    let all = Self.mutants(5)
    #expect(MutantSampling.sample(all.reversed(), limit: 5, seed: 1) == all)
  }

  @Test(
    "over the cap the same seed picks the same mutants whatever the input order, and another seed picks others — catches reruns judging a different sample"
  )
  func deterministic() {
    let all = Self.mutants(40)
    let first = MutantSampling.sample(all, limit: 10, seed: 42)
    #expect(first.count == 10)
    #expect(MutantSampling.sample(all.reversed(), limit: 10, seed: 42) == first)
    #expect(first == first.sorted { $0.line < $1.line })
    #expect(MutantSampling.sample(all, limit: 10, seed: 43) != first)
  }

  @Test(
    "the seed is a stable hash of the diff text, not the per-process randomized Hasher — catches reruns in a new process sampling differently"
  )
  func stableSeed() {
    #expect(MutantSampling.seed(diff: "") == 0xcbf2_9ce4_8422_2325)
    #expect(MutantSampling.seed(diff: "a") == 0xaf63_dc4c_8601_ec8c)
    #expect(MutantSampling.seed(diff: "a") != MutantSampling.seed(diff: "b"))
  }
}

@Suite("mutation rules")
struct MutationRulesTests {
  private static let text = "if a < b { go() }\n"

  private static func mutant(_ op: MutationOperator = .relationalBoundary) -> Mutant {
    switch op {
    case .removeCall:
      Mutant(
        file: "Core/F.swift", text: text, utf8Offset: 11, original: "go()", replacement: "",
        operator: .removeCall)!
    default:
      Mutant(
        file: "Core/F.swift", text: text, utf8Offset: 5, original: "<", replacement: "<=",
        operator: .relationalBoundary)!
    }
  }

  private static func run(
    _ results: [MutantResult], equivalent: [EquivalentMutant] = [],
    bare: [BareEquivalentMarker] = [], candidates: Int? = nil
  ) -> ChangedTestJudgement {
    MutationRules.judge(
      MutationRunSummary(
        results: results, equivalent: equivalent, bareMarkers: bare,
        candidateCount: candidates ?? results.count + equivalent.count, workers: 3))
  }

  @Test(
    "every mutant killed is GREEN with a per-mutant kill note and a kill rate — catches a strong test suite reported RED"
  )
  func allKilled() {
    let judgement = Self.run([
      MutantResult(mutant: Self.mutant(), outcome: .killed(failingTests: ["T.a()"])),
      MutantResult(mutant: Self.mutant(.removeCall), outcome: .timedOut(after: .seconds(20))),
    ])
    #expect(judgement.verdict == .green)
    let killed = judgement.findings.filter { $0.ruleID == MutationRules.killedRuleID }
    #expect(killed.count == 2 && killed.allSatisfy { !$0.severity.failsGate })
    #expect(killed.contains { $0.message.contains("timed out after 20s") })
    let summary = judgement.findings.first { $0.ruleID == MutationRules.summaryRuleID }
    #expect(summary?.message.contains("2 killed (1 timeout), 0 survived") == true)
    #expect(summary?.message.contains("kill rate 100%") == true)
    #expect(summary?.message.contains("3 workers") == true)
  }

  @Test(
    "a surviving mutant is RED at its file and line with operator and diff — catches a weak test passing ready"
  )
  func survivor() {
    let judgement = Self.run([
      MutantResult(mutant: Self.mutant(), outcome: .survived(testsRun: 4)),
      MutantResult(mutant: Self.mutant(.removeCall), outcome: .killed(failingTests: ["T.b()"])),
    ])
    #expect(judgement.verdict == .red)
    let survived = judgement.findings.filter { $0.ruleID == MutationRules.survivedRuleID }
    #expect(survived.count == 1)
    #expect(survived.first?.file == "Core/F.swift" && survived.first?.line == 1)
    #expect(survived.first?.message.contains("relational-boundary") == true)
    #expect(survived.first?.failureScenario?.contains("+if a <= b { go() }") == true)
    let summary = judgement.findings.first { $0.ruleID == MutationRules.summaryRuleID }
    #expect(summary?.message.contains("kill rate 50%") == true)
  }

  @Test(
    "a mutant no T1 test can reach survives — catches untested production lines counted as safe"
  )
  func noTests() {
    let judgement = Self.run([MutantResult(mutant: Self.mutant(), outcome: .noTests)])
    #expect(judgement.verdict == .red)
    #expect(
      judgement.findings.contains {
        $0.ruleID == MutationRules.survivedRuleID && $0.message.contains("no T1 test")
      })
  }

  @Test(
    "an unviable mutant is noted and left out of the kill rate; no evidence is BLOCKED — catches a compile error counted as a kill, or an environment failure as GREEN"
  )
  func unviableAndBlocked() {
    let unviable = Self.run([
      MutantResult(mutant: Self.mutant(), outcome: .unviable("type error")),
      MutantResult(mutant: Self.mutant(.removeCall), outcome: .killed(failingTests: ["T.a()"])),
    ])
    #expect(unviable.verdict == .green)
    let summary = unviable.findings.first { $0.ruleID == MutationRules.summaryRuleID }
    #expect(summary?.message.contains("1 unviable") == true)
    #expect(summary?.message.contains("kill rate 100%") == true)

    let blocked = Self.run([
      MutantResult(mutant: Self.mutant(), outcome: .noEvidence("baseline tests fail"))
    ])
    #expect(blocked.verdict == .blocked)
    #expect(blocked.findings.contains { $0.ruleID == MutationRules.noEvidenceRuleID })
  }

  @Test(
    "annotated equivalent mutants are counted, not run; a bare annotation is RED — catches the escape hatch used without a reason"
  )
  func equivalents() {
    let equivalent = EquivalentMutant(mutant: Self.mutant(), reason: "bound is unreachable")
    let judgement = Self.run(
      [], equivalent: [equivalent], bare: [BareEquivalentMarker(file: "Core/G.swift", line: 7)])
    #expect(judgement.verdict == .red)
    let bare = judgement.findings.filter { $0.ruleID == MutationRules.bareEquivalentRuleID }
    #expect(bare.first?.file == "Core/G.swift" && bare.first?.line == 7)
    let summary = judgement.findings.first { $0.ruleID == MutationRules.summaryRuleID }
    #expect(summary?.message.contains("1 equivalent") == true)
  }

  @Test(
    "sampling is named in the summary when candidates exceed the mutants run — catches a capped run read as exhaustive"
  )
  func sampled() {
    let judgement = Self.run(
      [MutantResult(mutant: Self.mutant(), outcome: .killed(failingTests: ["T.a()"]))],
      candidates: 9)
    let summary = judgement.findings.first { $0.ruleID == MutationRules.summaryRuleID }
    #expect(summary?.message.contains("1 mutant sampled from 9 candidates") == true)
  }
}

extension String {
  fileprivate func utf8Offset(of needle: String) -> Int? {
    range(of: needle).map { utf8.distance(from: utf8.startIndex, to: $0.lowerBound) }
  }
}

@Suite("mutation workers")
struct MutationWorkersTests {
  @Test(
    "by default workers are min(cores − 1, ceil(mutants / 2), 4) — catches one cold package build per core swamping memory on a many-core laptop"
  )
  func defaultCap() {
    #expect(MutationWorkers.count(configured: nil, cores: 18, mutants: 30) == 4)
    #expect(MutationWorkers.count(configured: nil, cores: 18, mutants: 5) == 3)
    #expect(MutationWorkers.count(configured: nil, cores: 3, mutants: 30) == 2)
    #expect(MutationWorkers.count(configured: nil, cores: 18, mutants: 1) == 1)
  }

  @Test(
    "a machine or run too small for the formula still gets one worker — catches a zero-worker run that judges nothing"
  )
  func atLeastOne() {
    #expect(MutationWorkers.count(configured: nil, cores: 1, mutants: 30) == 1)
    #expect(MutationWorkers.count(configured: nil, cores: 18, mutants: 0) == 1)
  }

  @Test(
    "a configured count replaces the formula but never exceeds the mutants to run — catches max_workers ignored, or idle workers each paying a cold build"
  )
  func configured() {
    #expect(MutationWorkers.count(configured: 8, cores: 18, mutants: 30) == 8)
    #expect(MutationWorkers.count(configured: 8, cores: 18, mutants: 3) == 3)
    #expect(MutationWorkers.count(configured: 1, cores: 18, mutants: 30) == 1)
  }

  @Test(
    "each worker's builds and test runs get an equal share of the cores, at least one — catches every worker compiling full width at once, oversubscribing the machine several times over"
  )
  func buildJobsShareTheCores() {
    #expect(MutationWorkers.buildJobs(configured: nil, cores: 16, workers: 4) == 4)
    #expect(MutationWorkers.buildJobs(configured: nil, cores: 18, workers: 4) == 4)
    #expect(MutationWorkers.buildJobs(configured: nil, cores: 18, workers: 1) == 18)
    #expect(MutationWorkers.buildJobs(configured: nil, cores: 2, workers: 4) == 1)
    #expect(MutationWorkers.buildJobs(configured: 3, cores: 18, workers: 2) == 3)
  }
}
