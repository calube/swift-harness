import SwiftGateDomain
import Testing

@Suite("ModuleScope resolvers")
struct ModuleScopeTests {
  @Test(
    "static scopes pick the longest matching directory — catches a nested module's files linted as its parent"
  )
  func longestPrefixWins() {
    let parent = ModuleScope(module: "Checkout", role: .core)
    let nested = ModuleScope(module: "CheckoutLive", role: .clientLive, kind: .client)
    let scopes = StaticModuleScopes([
      .init(scope: parent, directories: ["Packages/Checkout"]),
      .init(scope: nested, directories: ["Packages/Checkout/Live"]),
    ])
    #expect(scopes.scope(forFile: "Packages/Checkout/Live/Client.swift") == nested)
    #expect(scopes.scope(forFile: "Packages/Checkout/Reducer.swift") == parent)
    #expect(scopes.scope(forFile: "Packages/CheckoutExtras/X.swift") == nil)
    #expect(scopes.scope(ofModule: "CheckoutLive") == nested)
  }

  @Test(
    "path convention reads SwiftPM layout and never guesses T2 — catches fixtures or T2 targets misclassified"
  )
  func pathConvention() {
    let scopes = PathConventionModuleScopes()
    #expect(
      scopes.scope(forFile: "Packages/Pay/Tests/PayCoreTests/ReducerTests.swift")
        == ModuleScope(module: "PayCoreTests", role: .tests(.t1)))
    #expect(
      scopes.scope(forFile: "App/Tests/AppUITests/Flows/CheckoutTests.swift")?.role == .tests(.t3))
    #expect(scopes.scope(forFile: "Packages/Pay/Sources/PayLive/Client.swift")?.role == .clientLive)
    #expect(scopes.scope(forFile: "Packages/Pay/Sources/PayCore/Reducer.swift")?.role == .core)
    #expect(scopes.scope(forFile: "Packages/Pay/Sources/PayView/Screen.swift") == nil)
    #expect(scopes.scope(forFile: "Sources/Loose.swift") == nil)
    #expect(
      scopes.scope(forFile: "Pay/Tests/PayCoreTests/Fixtures/Sources/StubCore/X.swift")?.module
        == "PayCoreTests")
  }
}
