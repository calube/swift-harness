import SwiftGateDomain
import SwiftGateRules
import Testing

@Suite("surface-check body scan shapes")
struct SurfaceBodyScanShapeTests {
  private static let path = "Sources/App/New.swift"
  private static let noParent = SurfaceParentIndex(functions: [], types: [])

  /// Each judged declaration of `commitText`, as "<declaration>: <outcome>".
  private static func judged(
    _ commitText: String, parentText: String? = nil, parent: SurfaceParentIndex = noParent
  ) -> [String] {
    SurfaceBodyScan.judge(
      SurfaceFileChange(path: path, parentText: parentText, commitText: commitText),
      parent: parent
    )
    .map { "\($0.declaration): \($0.outcome)" }
  }

  private static func line(_ declaration: String, _ outcome: SurfaceJudgement.Outcome) -> String {
    "\(declaration): \(outcome)"
  }

  @Test(
    "the parent index holds class and actor names as types — catches a forward to a class's or actor's initializer judged as new code"
  )
  func parentIndexHoldsClassesAndActors() {
    let index = SurfaceParentIndex.build([
      "Services.swift": """
      final class Service {}
      actor Worker {}
      """
    ])

    #expect(index.types == ["Service", "Worker"])
  }

  @Test(
    "a declaration after a class, an actor or a protocol is named without that type — catches every later finding naming a type it isn't in"
  )
  func typesCloseAfterTheirBodies() {
    let judged = Self.judged(
      """
      final class Service {}
      func a() -> Int { compute() }
      actor Worker {}
      func b() -> Int { compute() }
      protocol Loading {}
      func c() -> Int { compute() }
      """)

    let newCode = SurfaceJudgement.Outcome.behaviour(.forwardsToNewCode(callee: "compute"))
    #expect(
      judged == [Self.line("a()", newCode), Self.line("b()", newCode), Self.line("c()", newCode)])
  }

  @Test(
    "a deinit body is judged like any function body — catches cleanup work in a surface commit's deinit passing unseen"
  )
  func deinitIsJudged() {
    #expect(
      Self.judged("final class Cache { deinit { flush() } }")
        == [Self.line("Cache.deinit", .behaviour(.forwardsToNewCode(callee: "flush")))])
  }

  @Test(
    "a list that gains another copy of a type it already lists is still a registration, and new types beside any other change are a changed value — catches each parent entry matched twice, or a changed list passing as registrations"
  )
  func registrationsMatchEachParentEntryOnce() {
    let parentText = """
      enum Commands {
        static let all: [Any.Type] = [Build.self]
        static let extra: [Any.Type] = [Build.self] + base
      }
      """
    let commitText = """
      enum Commands {
        static let all: [Any.Type] = [Build.self, Build.self]
        static let extra: [Any.Type] = [Build.self, Test.self] + other
      }
      """

    #expect(
      Self.judged(commitText, parentText: parentText) == [
        Self.line("Commands.all", .stub(.registersType)),
        Self.line("Commands.extra", .behaviour(.changesStoredValue)),
      ])
  }

  @Test(
    "an added switch case holding its own switch is judged once, as the outer case — catches each nested case reported again as a clause of its own"
  )
  func addedCaseWithNestedSwitchIsJudgedOnce() {
    let parentText = """
      func mode(_ a: Int, _ b: Int) -> String {
        switch a {
        case 0: return "zero"
        }
      }
      """
    let commitText = """
      func mode(_ a: Int, _ b: Int) -> String {
        switch a {
        case 0: return "zero"
        case 1:
          switch b {
          case 0: return "one"
          default: return ""
          }
        }
      }
      """

    let declarations = SurfaceBodyScan.judge(
      SurfaceFileChange(path: Self.path, parentText: parentText, commitText: commitText),
      parent: Self.noParent
    )
    .map(\.declaration)
    #expect(declarations == ["mode(_:_:) case 1"])
  }

  @Test(
    "a stored value that gains a trailing closure has only the closure judged — catches the closure's own braces making the unchanged value look changed"
  )
  func addedClosureLeavesValueUnchanged() {
    let parentText = """
      struct Screen {
        var action = Button("Go")
      }
      """
    let commitText = """
      struct Screen {
        var action = Button("Go") {}
      }
      """

    #expect(
      Self.judged(commitText, parentText: parentText) == [
        Self.line("Screen.action", .stub(.empty))
      ])
  }

  @Test(
    "a #Preview inside a type is judged like one at file scope — catches sample data in a member preview passing unseen"
  )
  func memberPreviewIsJudged() {
    #expect(
      Self.judged(
        """
        struct CounterView_Previews {
          #Preview { Text("sample") }
        }
        """) == [Self.line("#Preview", .behaviour(.sampleData(literal: "\"sample\"")))])
  }

  @Test(
    "previews are matched to the parent's by position, so a preview changed to match another is still judged — catches a changed preview hidden behind a sibling with the same body"
  )
  func previewsMatchByPosition() {
    let parentText = """
      #Preview { EmptyView() }
      #Preview { Text("sample") }
      """
    let commitText = """
      #Preview { Text("sample") }
      #Preview { Text("sample") }
      """

    #expect(
      Self.judged(commitText, parentText: parentText) == [
        Self.line("#Preview", .behaviour(.sampleData(literal: "\"sample\"")))
      ])
  }

  @Test(
    "`Type.init(…)` from empty defaults and parameters is an empty value whether the type is plain or nested, and a lowercase base isn't a type — catches a nested type's initializer rejected as new code, or a value's init passing as a stub"
  )
  func explicitInitializerCallsAreEmptyValues() {
    let judged = Self.judged(
      """
      func a() -> Config { Config.init(count: 0) }
      func b(name: String) -> Outer.Inner { Outer.Inner.init(name: name) }
      func c() -> Config { config.init() }
      """)

    #expect(
      judged == [
        Self.line("a()", .stub(.emptyValue)),
        Self.line("b(name:)", .stub(.emptyValue)),
        Self.line("c()", .behaviour(.forwardsToNewCode(callee: "config"))),
      ])
  }

  @Test(
    "a function reference and a throw of a variable or of a member reached through a property are not stubs — catches `handle(_:)` passing as an unchanged value, or any thrown value passing as an error stub"
  )
  func referencesAndThrownValuesAreNotStubs() {
    let judged = Self.judged(
      """
      func handler() -> (Int) -> Void { handle(_:) }
      func fail() throws { throw lastError }
      func offline() throws { throw Errors.shared.offline }
      """)

    #expect(
      judged == [
        Self.line("handler()", .behaviour(.notAStub(excerpt: "handle(_:)"))),
        Self.line("fail()", .behaviour(.notAStub(excerpt: "throw lastError"))),
        Self.line("offline()", .behaviour(.notAStub(excerpt: "throw Errors.shared.offline"))),
      ])
  }

  @Test(
    "a non-empty dictionary literal returned from a body is not an empty default — catches `[\"a\": 1]` passing as `[:]`"
  )
  func nonEmptyDictionaryIsNotEmptyDefault() {
    #expect(
      Self.judged("func weights() -> [String: Int] { [\"a\": 1] }")
        == [Self.line("weights()", .behaviour(.notAStub(excerpt: "[\"a\": 1]")))])
  }

  @Test(
    "a forward may pass a member, an inout argument, an empty default or a payload-free case — catches a plain forward to parent code rejected as not a stub"
  )
  func forwardsPassPlainArguments() {
    let judged = Self.judged(
      """
      func a() { save(self.item) }
      func b() { load(&buffer) }
      func c() { reset(0) }
      func d() { reset(.all) }
      """,
      parent: SurfaceParentIndex(functions: ["save", "load", "reset"], types: []))

    let forward = SurfaceJudgement.Outcome.stub(.forward)
    #expect(
      judged == [
        Self.line("a()", forward), Self.line("b()", forward), Self.line("c()", forward),
        Self.line("d()", forward),
      ])
  }

  @Test(
    "a reducer that chains an operator onto Reduce, passes Reduce a function, mutates state, or hides a case in #if does work — catches reducer logic passing as a `.none` stub"
  )
  func reducerWorkShapes() {
    let judged = Self.judged(
      """
      struct Chained {
        var body: some ReducerOf<Self> {
          Reduce { _, _ in .none }.ifLet(\\.child, action: \\.child) { Child() }
        }
      }
      struct Passed {
        var body: some ReducerOf<Self> {
          Reduce(core)
        }
      }
      struct Mutating {
        var body: some ReducerOf<Self> {
          Reduce { state, _ in
            state.count += 1
            return .none
          }
        }
      }
      struct Switched {
        var body: some ReducerOf<Self> {
          Reduce { state, action in
            switch action {
            case .tap:
              state.count = 1
              return .none
            }
          }
        }
      }
      struct Conditional {
        var body: some ReducerOf<Self> {
          Reduce { _, action in
            switch action {
            #if DEBUG
            case .debug: return .none
            #endif
            }
          }
        }
      }
      """)

    #expect(
      judged == [
        Self.line(
          "Chained.body",
          .behaviour(
            .reducerWork(
              excerpt: "Reduce { _, _ in .none }.ifLet(\\.child, action: \\.child) { Child() }"))),
        Self.line("Passed.body", .behaviour(.reducerWork(excerpt: "Reduce(core)"))),
        Self.line("Mutating.body", .behaviour(.reducerWork(excerpt: "state.count += 1"))),
        Self.line("Switched.body", .behaviour(.reducerWork(excerpt: "state.count = 1"))),
        Self.line(
          "Conditional.body",
          .behaviour(
            .reducerWork(
              excerpt: "switch action { #if DEBUG case .debug: return .none #endif }"))),
      ])
  }

  @Test(
    "a preview holding a non-zero float, true, a non-empty array or dictionary, or a regex holds sample data, and one with only [:] and 0.0 holds none — catches sample data passing as a data-free preview, or an empty literal rejected"
  )
  func previewLiteralsThatHoldData() {
    let judged = Self.judged(
      """
      #Preview { Slider(value: .constant(0.5)) }
      #Preview { Toggle(isOn: .constant(true)) { EmptyView() } }
      #Preview { Picker(items: [.a, .b]) }
      #Preview { Grid(values: [key: value]) }
      #Preview { Filter(pattern: #/a+/#) }
      #Preview { Grid(values: [:], scale: 0.0) }
      """)

    #expect(
      judged == [
        Self.line("#Preview", .behaviour(.sampleData(literal: "0.5"))),
        Self.line("#Preview", .behaviour(.sampleData(literal: "true"))),
        Self.line("#Preview", .behaviour(.sampleData(literal: "[.a, .b]"))),
        Self.line("#Preview", .behaviour(.sampleData(literal: "[key: value]"))),
        Self.line("#Preview", .behaviour(.sampleData(literal: "#/a+/#"))),
        Self.line("#Preview", .stub(.previewWithoutData)),
      ])
  }
}
