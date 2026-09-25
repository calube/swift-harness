import APIClient
import Dependencies
import Testing

/// The interface's contract with the features that depend on it: tests must stub what they use,
/// and an override set in a dependency context is the one a feature reads.
@Suite
struct APIClientTests {
  @Test(
    "the test value fails an unstubbed call instead of answering — catches a feature test passing on a made-up fact it never stubbed"
  )
  func unstubbedCallFails() async {
    let client = APIClient.testValue

    await withKnownIssue {
      await #expect(throws: (any Error).self) { try await client.randomFact() }
    } matching: { issue in
      issue.description.contains("randomFact")
    }
  }

  @Test(
    "an override set with withDependencies is what @Dependency(\\.apiClient) reads — catches the accessor wired to a different key than the override"
  )
  func overrideReachesReaders() async throws {
    let fact = try await withDependencies {
      $0.apiClient.randomFact = { Fact(text: "stubbed") }
    } operation: {
      @Dependency(\.apiClient) var apiClient
      return try await apiClient.randomFact()
    }

    #expect(fact == Fact(text: "stubbed"))
  }

  @Test(
    "the preview value answers without a transport — catches previews and snapshots reaching for the network"
  )
  func previewAnswersOffline() async throws {
    let fact = try await withDependencies {
      $0.context = .preview
    } operation: {
      @Dependency(\.apiClient) var apiClient
      return try await apiClient.randomFact()
    }

    #expect(fact.text == "Cats sleep for around 13 to 14 hours a day.")
  }
}
