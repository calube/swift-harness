import SwiftGateDomain
import SwiftGateRules
import Testing

@Suite("surface-check body scan")
struct SurfaceBodyScanTests {
  private static func added(_ text: String) -> SurfaceFileChange {
    SurfaceFileChange(path: "Sources/App/New.swift", parentText: nil, commitText: text)
  }

  @Test(
    "the parent index holds declared functions, properties and nested types, never a body's locals — catches a forward to a local helper counted as code on the parent"
  )
  func parentIndexSkipsLocals() {
    let index = SurfaceParentIndex.build([
      "A.swift": """
      struct Outer {
        enum Inner {}
        var fetch: () -> Int
        func load() -> Int {
          func localHelper() -> Int { 0 }
          let localValue = 1
          return localHelper() + localValue
        }
      }
      typealias Alias = Outer
      """
    ])

    #expect(index.functions == ["fetch", "load"])
    #expect(index.types == ["Outer", "Inner", "Alias"])
  }

  @Test(
    "only forward-shaped bodies name a callee, so a commit without one never reads the parent — catches every stub asking for the parent's tree"
  )
  func forwardCalleesNameOnlyForwards() {
    let change = Self.added(
      """
      func a() -> Int { existing() }
      func b() -> Int { 0 }
      func c() -> Item { Item(name: name) }
      func d() -> Int { compute(1 + 2) }
      """)

    #expect(SurfaceBodyScan.forwardCallees(in: change) == ["existing", "Item"])
  }

  @Test(
    "a member of a nested type is qualified by every enclosing type, and an added default branch is named default — catches a finding that names the wrong declaration"
  )
  func qualifiedNamesAndDefaultBranch() {
    let parentText = """
      struct Outer {
        struct Inner {
          func mode(_ flag: Int) -> String {
            switch flag {
            case 0: return "zero"
            }
          }
        }
      }
      """
    let commitText = """
      struct Outer {
        struct Inner {
          func mode(_ flag: Int) -> String {
            switch flag {
            case 0: return "zero"
            default: return "many"
            }
          }
        }
      }
      """
    let judgements = SurfaceBodyScan.judge(
      SurfaceFileChange(
        path: "Sources/App/Mode.swift", parentText: parentText, commitText: commitText),
      parent: SurfaceParentIndex(functions: [], types: []))

    #expect(
      judgements == [
        SurfaceJudgement(
          file: "Sources/App/Mode.swift", line: 6, declaration: "Outer.Inner.mode(_:) default",
          outcome: .behaviour(.notAStub(excerpt: "return \"many\"")))
      ])
  }

  @Test(
    "a reducer body is EmptyReducer or Reduce returning .none; composing a child reducer is work, and a trap in a preview is a trap — catches reducer composition or a trapping preview passing as a stub"
  )
  func reducerCompositionAndPreviewTrap() {
    let change = Self.added(
      """
      struct Idle {
        var body: some ReducerOf<Self> {
          EmptyReducer()
        }
      }
      struct Parent {
        var body: some ReducerOf<Self> {
          Scope(state: \\.child, action: \\.child) { Child() }
        }
      }
      #Preview {
        fatalError()
      }
      """)

    let outcomes = SurfaceBodyScan.judge(
      change, parent: SurfaceParentIndex(functions: [], types: [])
    )
    .map { "\($0.declaration): \($0.outcome)" }

    #expect(
      outcomes == [
        "Idle.body: \(SurfaceJudgement.Outcome.stub(.reducerNone))",
        "Parent.body: \(SurfaceJudgement.Outcome.behaviour(.reducerWork(excerpt: "Scope(state: \\.child, action: \\.child) { Child() }")))",
        "#Preview: \(SurfaceJudgement.Outcome.behaviour(.traps(callee: "fatalError")))",
      ])
  }

  @Test(
    "the parent index holds enum case names, a body building a case the file doesn't declare names it so the parent is read, and a case the file declares needs no parent — catches a parent-declared case never looked up, or a new case rejected"
  )
  func payloadCasesResolveAgainstParentOrFile() {
    let index = SurfaceParentIndex.build([
      "Status.swift": """
      enum ExitStatus {
        case exited(Int32), signalled(Int32)
        case idle
        func label() -> String {
          enum Local { case hidden(Int) }
          return ""
        }
      }
      """
    ])
    let parentCase = Self.added("func run() -> ExitStatus { .exited(0) }")
    let fileCase = Self.added(
      """
      enum Phase { case waiting(String) }
      func phase(name: String) -> Phase { .waiting(name) }
      """)

    #expect(index.cases == ["exited", "signalled", "idle"])
    #expect(SurfaceBodyScan.forwardCallees(in: parentCase) == ["exited"])
    #expect(SurfaceBodyScan.forwardCallees(in: fileCase) == [])
    #expect(
      SurfaceBodyScan.judge(fileCase, parent: SurfaceParentIndex(functions: [], types: []))
        .map(\.outcome) == [.stub(.emptyPayloadCase)])
  }

  @Test(
    "a throw of a case on a nested error type, `Outer.Inner.case`, passes as a throw-only stub — catches a qualified type name rejected as behaviour"
  )
  func throwOfNestedTypeCaseIsStub() {
    let change = Self.added(
      """
      enum LoadError: Error { enum Network: Error { case offline } }
      func load() throws { throw LoadError.Network.offline }
      """)

    #expect(
      SurfaceBodyScan.judge(change, parent: SurfaceParentIndex(functions: [], types: []))
        .map(\.outcome) == [.stub(.throwsError)])
  }
}
