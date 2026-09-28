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

  private static let manifest = """
    // swift-tools-version: 6.2
    import PackageDescription

    let package = Package(
      name: "App",
      targets: [
        .target(name: "App", swiftSettings: [.unsafeFlags(["-Osize"])]),
        .testTarget(name: "AppTests", dependencies: ["App"]),
      ]
    )
    """

  private static func manifestChange(_ commitText: String) -> [SurfaceJudgement.Outcome] {
    SurfaceBodyScan.judge(
      SurfaceFileChange(path: "Package.swift", parentText: manifest, commitText: commitText),
      parent: SurfaceParentIndex(functions: [], types: [])
    )
    .map(\.outcome)
  }

  @Test(
    "a manifest that only gains a comment, blank lines or a trailing comma judges nothing — catches a formatting touch refused as a manifest change"
  )
  func reformattedManifestJudgesNothing() {
    let reformatted = Self.manifest
      .replacingOccurrences(
        of: "import PackageDescription\n", with: "import PackageDescription\n\n// App.\n"
      )
      .replacingOccurrences(of: "dependencies: [\"App\"]", with: "dependencies: [\"App\",]")

    #expect(reformatted != Self.manifest)
    #expect(Self.manifestChange(reformatted) == [])
  }

  @Test(
    "a string added to a list outside dependencies, products and targets is a manifest change, while a target name added to a dependencies list is a stub — catches a new compiler flag passing as a target name"
  )
  func stringOutsideTheTargetListsIsBehaviour() {
    let flag = Self.manifest.replacingOccurrences(
      of: "[\"-Osize\"]", with: "[\"-Osize\", \"-Ounchecked\"]")
    let dependency = Self.manifest.replacingOccurrences(
      of: "dependencies: [\"App\"]", with: "dependencies: [\"App\", \"Support\"]")

    #expect(Self.manifestChange(flag) == [.behaviour(.changesManifest(excerpt: "\"-Ounchecked\""))])
    #expect(Self.manifestChange(dependency) == [.stub(.extendsManifest)])
  }

  private static func manifestChange(from parentText: String, to commitText: String)
    -> [SurfaceJudgement.Outcome]
  {
    SurfaceBodyScan.judge(
      SurfaceFileChange(path: "Package.swift", parentText: parentText, commitText: commitText),
      parent: SurfaceParentIndex(functions: [], types: [])
    )
    .map(\.outcome)
  }

  @Test(
    "a manifest that drops its tools-version line is a manifest change naming the line it lost — catches the dropped line reported as an empty excerpt"
  )
  func droppedToolsVersionNamesTheOldLine() {
    let dropped = Self.manifest.replacingOccurrences(of: "// swift-tools-version: 6.2\n", with: "")

    #expect(dropped != Self.manifest)
    #expect(
      Self.manifestChange(dropped)
        == [.behaviour(.changesManifest(excerpt: "// swift-tools-version: 6.2"))])
  }

  @Test(
    "a manifest that loses a statement, or a call's last argument, is a manifest change naming what it lost — catches a removal passing as a manifest that judges nothing, or named by an empty excerpt"
  )
  func removalNamesWhatWasLost() {
    let appended = Self.manifest + "\npackage.targets.append(.target(name: \"Extra\"))\n"
    let argumentDropped = Self.manifest.replacingOccurrences(
      of: ".testTarget(name: \"AppTests\", dependencies: [\"App\"])",
      with: ".testTarget(name: \"AppTests\")")

    #expect(
      Self.manifestChange(from: appended, to: Self.manifest)
        == [
          .behaviour(
            .changesManifest(excerpt: "package.targets.append(.target(name: \"Extra\"))"))
        ])
    #expect(argumentDropped != Self.manifest)
    #expect(
      Self.manifestChange(argumentDropped)
        == [.behaviour(.changesManifest(excerpt: "dependencies: [\"App\"]"))])
  }

  @Test(
    "an interpolated target name added to a dependencies list is a manifest change — catches a computed name passing as a declared target"
  )
  func interpolatedDependencyIsBehaviour() {
    let interpolated = Self.manifest.replacingOccurrences(
      of: "dependencies: [\"App\"]", with: "dependencies: [\"App\", \"\\(name)\"]")

    #expect(
      Self.manifestChange(interpolated)
        == [.behaviour(.changesManifest(excerpt: "\"\\(name)\""))])
  }

  @Test(
    "a target name replaced by a product, or renamed, is a manifest change naming the old name or the changed argument — catches a replacement named by its new element, or an excerpt keeping the argument's comma"
  )
  func replacedElementNamesWhatChanged() {
    let product = Self.manifest.replacingOccurrences(
      of: "dependencies: [\"App\"]",
      with: "dependencies: [.product(name: \"App\", package: \"Support\")]")
    let renamed = Self.manifest.replacingOccurrences(
      of: ".target(name: \"App\",", with: ".target(name: \"Apps\",")

    #expect(Self.manifestChange(product) == [.behaviour(.changesManifest(excerpt: "\"App\""))])
    #expect(renamed != Self.manifest)
    #expect(
      Self.manifestChange(renamed) == [.behaviour(.changesManifest(excerpt: "name: \"Apps\""))])
  }

  @Test(
    "2 target names swapped in a dependencies list are a manifest change naming the one that moved later — catches the named element flipping with the alignment's tie-break"
  )
  func swappedDependenciesNameTheFirst() {
    let parent = Self.manifest.replacingOccurrences(
      of: "dependencies: [\"App\"]", with: "dependencies: [\"App\", \"Support\"]")
    let swapped = Self.manifest.replacingOccurrences(
      of: "dependencies: [\"App\"]", with: "dependencies: [\"Support\", \"App\"]")

    #expect(
      Self.manifestChange(from: parent, to: swapped)
        == [.behaviour(.changesManifest(excerpt: "\"App\""))])
  }

  @Test(
    "a changed statement outside any labelled argument is named by the statement, cut to 100 characters — catches the whole file reported, or a long excerpt emptied"
  )
  func changedStatementIsNamedAndCut() {
    let changed = Self.manifest.replacingOccurrences(of: "let package", with: "var package")

    #expect(
      Self.manifestChange(changed)
        == [
          .behaviour(
            .changesManifest(
              excerpt:
                "var package = Package( name: \"App\", targets: [ .target(name: \"App\", "
                + "swiftSettings: [.unsafeFlags([\"-…"))
        ])
  }

  @Test(
    "an excerpt of exactly 100 characters is kept whole and one of 101 is cut with an ellipsis — catches the cut moving off its boundary"
  )
  func excerptCutsAfter100Characters() {
    func flag(_ length: Int) -> String {
      "\"-D" + String(repeating: "X", count: length - 4) + "\""
    }
    func added(_ flag: String) -> String {
      Self.manifest.replacingOccurrences(of: "[\"-Osize\"]", with: "[\"-Osize\", \(flag)]")
    }

    #expect(flag(100).count == 100)
    #expect(
      Self.manifestChange(added(flag(100))) == [.behaviour(.changesManifest(excerpt: flag(100)))])
    #expect(
      Self.manifestChange(added(flag(101)))
        == [.behaviour(.changesManifest(excerpt: String(flag(101).prefix(100)) + "…"))])
  }
}
