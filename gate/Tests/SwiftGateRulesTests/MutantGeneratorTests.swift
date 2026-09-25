import SwiftGateDomain
import SwiftGateRules
import Testing

@Suite("mutant generation")
struct MutantGeneratorTests {
  private static let path = "Core/Sources/Core/F.swift"

  /// Every mutant of `source` on all of its lines, as mutated source per operator.
  private func mutated(
    _ source: String, lines: [ClosedRange<Int>]? = nil, _ mutationOperator: MutationOperator
  ) -> [String] {
    candidates(source, lines: lines).mutants
      .filter { $0.mutationOperator == mutationOperator }
      .compactMap { $0.apply(to: source) }
  }

  private func candidates(_ source: String, lines: [ClosedRange<Int>]? = nil)
    -> MutationCandidates
  {
    let lineCount = source.split(separator: "\n", omittingEmptySubsequences: false).count
    let unit = SourceUnit(
      input: SourceInput(path: Self.path, text: source),
      scope: ModuleScope(module: "Core", role: .core))
    return MutantGenerator.candidates(
      in: unit, text: source,
      added: AddedLines(path: Self.path, ranges: lines ?? [1...lineCount]))
  }

  @Test(
    "negate-conditional wraps if, guard, while and repeat conditions, unwraps a negation, and leaves literal conditions alone — catches a branch no test distinguishes, or an unviable `while !(true)`"
  )
  func negateConditional() {
    let source = """
      func f(a: Bool, b: Int) {
        if a { go() }
        guard b > 1, !a else { return }
        while a { go() }
        repeat { go() } while b == 2
        if let x = Optional(b) { use(x) }
        while true { if a { break } }
      }
      """
    let results = mutated(source, .negateConditional)
    #expect(results.count == 6)
    #expect(results.contains { $0.contains("if !(a) { go() }") })
    #expect(!results.contains { $0.contains("!(true)") })
    #expect(results.contains { $0.contains("guard !(b > 1), !a else") })
    #expect(results.contains { $0.contains("guard b > 1, a else") })
    #expect(results.contains { $0.contains("while !(a) { go() }") })
    #expect(results.contains { $0.contains("} while !(b == 2)") })
  }

  @Test(
    "relational-boundary swaps < with <= and > with >= and leaves generics alone — catches an off-by-one no test pins"
  )
  func relationalBoundary() {
    let source = """
      func f(a: Int, b: Array<Int>) -> Bool {
        a < 3 || a >= 7 || a == 5
      }
      """
    let results = mutated(source, .relationalBoundary)
    #expect(
      results.sorted()
        == [
          source.replacingOccurrences(of: "a < 3", with: "a <= 3"),
          source.replacingOccurrences(of: "a >= 7", with: "a > 7"),
        ].sorted())
  }

  @Test(
    "return-default replaces returned values with the declared type's default, including single-expression bodies, and skips closures and unknown types — catches a result no test asserts"
  )
  func returnDefault() {
    let source = """
      struct S {
        var done: Bool { count > 3 }
        var count: Int { return items.count }
        func name() -> String { return "x" }
        func maybe() -> Int? { 1 }
        func list() -> [Int] { return [1] }
        func map() -> [String: Int] { return ["a": 1] }
        func already() -> Bool { return false }
        func custom() -> Thing { return Thing() }
        func closure() -> Int { let f = { return 3 }; return f() }
      }
      """
    let results = mutated(source, .returnDefault)
    #expect(results.contains { $0.contains("var done: Bool { false }") })
    #expect(results.contains { $0.contains("var count: Int { return 0 }") })
    #expect(results.contains { $0.contains(#"func name() -> String { return "" }"#) })
    #expect(results.contains { $0.contains("func maybe() -> Int? { nil }") })
    #expect(results.contains { $0.contains("func list() -> [Int] { return [] }") })
    #expect(results.contains { $0.contains("func map() -> [String: Int] { return [:] }") })
    #expect(results.contains { $0.contains("func already() -> Bool { return true }") })
    #expect(results.contains { $0.contains("let f = { return 3 }; return 0") })
    #expect(results.count == 8)
  }

  @Test(
    "remove-call drops call statements whose result is unused, keeps implicit returns and assertions, and leaves a switch case compilable — catches a side effect no test observes"
  )
  func removeCall() {
    let source = """
      func f(x: Int) -> Int {
        log(x)
        try store.save(x)
        precondition(x > 0)
        switch x {
        case 1: notify()
        default: break
        }
        let y = compute(x)
        return y
      }
      func g() -> Int { compute(1) }
      let preview = Client(fetch: { Fact(text: "x") })
      let retried = { [request] in try await http.data(for: request) }
      """
    let results = mutated(source, .removeCall)
    #expect(results.count == 3)
    #expect(results.contains { !$0.contains("log(x)") })
    #expect(results.contains { !$0.contains("try store.save(x)") })
    #expect(results.contains { $0.contains("case 1: break") })
  }

  @Test(
    "remove-effect in a TCA file turns returned effects into .none and removes sends, which remove-call then skips — catches an effect no TestStore receives"
  )
  func removeEffect() {
    let source = """
      import ComposableArchitecture
      func reduce(into state: inout State, action: Action) -> Effect<Action> {
        switch action {
        case .tapped:
          return .send(.loaded)
        case .load:
          return .run { send in
            await send(.loaded)
          }
          .cancellable(id: ID.load)
        case .loaded:
          return .none
        }
      }
      """
    let results = mutated(source, .removeEffect)
    #expect(results.count == 3)
    #expect(results.contains { $0.contains("case .tapped:\n    return .none") })
    #expect(results.contains { $0.contains("case .load:\n    return .none\n  case .loaded") })
    #expect(results.contains { !$0.contains("await send(.loaded)") })
    #expect(mutated(source, .removeCall).isEmpty)
  }

  @Test(
    "without a TCA import send is an ordinary call — catches effect operators firing on non-reducer code"
  )
  func sendOutsideTCA() {
    let source = "func f() {\n  send(1)\n}\n"
    #expect(mutated(source, .removeEffect).isEmpty)
    #expect(mutated(source, .removeCall) == ["func f() {\n  \n}\n"])
  }

  @Test("only lines added by the change are mutated — catches mutating untouched code")
  func onlyAddedLines() {
    let source = "func f(a: Int) -> Bool {\n  if a < 1 { return true }\n  return a > 2\n}\n"
    let mutants = candidates(source, lines: [3...3]).mutants
    #expect(!mutants.isEmpty)
    #expect(mutants.allSatisfy { $0.line == 3 })
  }

  @Test(
    "a line annotated equivalent-mutant with a reason sets its mutants aside; without a reason it is a bare marker — catches the annotation silencing mutants unexplained"
  )
  func equivalentAnnotation() {
    let source = """
      func f(a: Int) -> Bool {
        if a < 1 { return true }  // swiftgate:equivalent-mutant — a is never 1 here
        return a > 2  // swiftgate:equivalent-mutant
      }
      """
    let result = candidates(source)
    #expect(result.mutants.allSatisfy { $0.line != 2 })
    #expect(!result.equivalent.isEmpty)
    #expect(result.equivalent.allSatisfy { $0.mutant.line == 2 })
    #expect(result.equivalent.first?.reason == "a is never 1 here")
    #expect(result.bareMarkers == [BareEquivalentMarker(file: Self.path, line: 3)])
    #expect(result.mutants.contains { $0.line == 3 })
  }
}
