import Dependencies

extension APIClient: TestDependencyKey {
  public static let testValue = APIClient()
}
