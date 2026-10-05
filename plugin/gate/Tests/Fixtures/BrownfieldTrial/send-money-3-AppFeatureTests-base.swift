import APIClient
import AppCore
import ComposableArchitecture
import LogClient
import Testing

@MainActor
struct AppFeatureTests {
  nonisolated static let posts = [
    Post(id: 1, userId: 1, title: "First", body: "One"),
    Post(id: 2, userId: 1, title: "Second", body: "Two"),
  ]

  @Test("appearing loads posts and shows their count — catches the loading state never resolving")
  func taskLoadsPosts() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.apiClient.fetchPosts = { Self.posts }
    }

    await store.send(.task) { $0.status = .loading }
    await store.receive(\.postsResponse.success) { $0.status = .loaded(postCount: 2) }
  }

  @Test(
    "a failed load shows the error and logs it — catches a stuck spinner and a silent failure")
  func failureLogs() async {
    let records = LockIsolated<[LogRecord]>([])
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.apiClient.fetchPosts = { throw APIError.offline }
      $0.logClient.emit = { record in records.withValue { $0.append(record) } }
    }

    await store.send(.task) { $0.status = .loading }
    await store.receive(\.postsResponse.failure) { $0.status = .failed(.offline) }
    #expect(
      records.value == [
        LogRecord(
          level: .error, category: "App", message: "posts request failed",
          attributes: [.public("error", "offline")])
      ]
    )
  }

  @Test("retry after a failure loads again — catches the retry button doing nothing")
  func retryReloads() async {
    let store = TestStore(initialState: AppFeature.State(status: .failed(.badStatus(503)))) {
      AppFeature()
    } withDependencies: {
      $0.apiClient.fetchPosts = { Self.posts }
    }

    await store.send(.retryButtonTapped) { $0.status = .loading }
    await store.receive(\.postsResponse.success) { $0.status = .loaded(postCount: 2) }
  }

  @Test(
    "an unexpected error type still ends loading — catches a non-API error leaving the spinner up")
  func unexpectedErrorEndsLoading() async {
    struct Unexpected: Error {}
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.apiClient.fetchPosts = { throw Unexpected() }
    }

    await store.send(.task) { $0.status = .loading }
    await store.receive(\.postsResponse.failure) { $0.status = .failed(.undecodable) }
  }
}
