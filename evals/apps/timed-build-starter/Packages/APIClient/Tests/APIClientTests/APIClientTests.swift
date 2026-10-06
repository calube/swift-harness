import APIClient
import Dependencies
import Testing

struct APIClientTests {
  @Test(
    "the test value fails an unstubbed call instead of answering — catches a feature test passing on posts it never stubbed"
  )
  func unstubbedCallFails() async {
    let client = APIClient.testValue

    await withKnownIssue {
      await #expect(throws: (any Error).self) { try await client.fetchPosts() }
    } matching: { issue in
      issue.description.contains("fetchPosts")
    }
  }

  @Test(
    "an override set with withDependencies is what @Dependency(\\.apiClient) reads — catches the accessor wired to a different key than the override"
  )
  func overrideReachesReaders() async throws {
    let stub = Post(id: 9, userId: 3, title: "stubbed", body: "body")
    let posts = try await withDependencies {
      $0.apiClient.fetchPosts = { [stub] }
    } operation: {
      @Dependency(\.apiClient) var apiClient
      return try await apiClient.fetchPosts()
    }

    #expect(posts == [stub])
  }

  @Test(
    "the preview value answers without a network — catches previews reaching for the real API")
  func previewAnswersOffline() async throws {
    let posts = try await withDependencies {
      $0.context = .preview
    } operation: {
      @Dependency(\.apiClient) var apiClient
      return try await apiClient.fetchPosts()
    }

    #expect(posts.map(\.title) == ["Preview post", "Another preview post"])
  }
}
