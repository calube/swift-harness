import Foundation
import SwiftGateDomain
import Testing

@Suite("Repository profile (design spec §5.1)")
struct RepositoryProfileConfigTests {
  private func root(harness: ConfigValue?) -> ConfigValue {
    var table: [String: ConfigValue] = [
      "schema": .integer(1),
      "xcode": .string("26.2"),
      "app_scheme": .string("App"),
      "packages": .array([.string("Packages/*")]),
      "simulator": .table(["device": .string("iPhone 17"), "os": .string("26.2")]),
    ]
    if let harness { table["harness"] = harness }
    return .table(table)
  }

  @Test(
    "a [harness] profile names the preset a build uses, and a repository with no [harness] table keeps default — catches a profile silently ignored, or an older config losing its default"
  )
  func profileResolvesPresetName() {
    let named = decoded(root(harness: .table(["profile": .string("timed")])))
    #expect(named?.profile == "timed")
    #expect(named?.profileName == "timed")

    let unnamed = decoded(root(harness: nil))
    #expect(unnamed != nil)
    #expect(unnamed?.profile == nil)
    #expect(unnamed?.profileName == "default")
  }

  /// The config, or `nil` with the load error recorded as this test's issue.
  private func decoded(_ document: ConfigValue) -> Config? {
    do {
      return try ConfigSchema.config(from: document)
    } catch {
      Issue.record("the config does not load: \(error)")
      return nil
    }
  }

  @Test(
    "an unknown [harness] key, a non-string profile and a blank profile are each a config issue — catches a typo or an empty profile read as no profile"
  )
  func malformedHarnessTableIsAnIssue() {
    let cases: [(ConfigValue, [ConfigIssue])] = [
      (
        .table(["profile": .string("timed"), "profiel": .string("x")]),
        [.unknownKey(path: "harness.profiel")]
      ),
      (
        .table(["profile": .integer(1)]),
        [.wrongType(path: "harness.profile", expected: "string", found: "integer")]
      ),
      (.table(["profile": .string("  ")]), [.emptyValue(path: "harness.profile")]),
    ]
    for (harness, expected) in cases {
      #expect {
        _ = try ConfigSchema.config(from: root(harness: harness))
      } throws: { error in
        (error as? ConfigValidationError)?.issues == expected
      }
    }
  }
}
