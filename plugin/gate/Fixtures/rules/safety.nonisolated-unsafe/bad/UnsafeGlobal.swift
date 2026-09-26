nonisolated(unsafe) var cache: [String: Int] = [:]
struct Holder {
  nonisolated(unsafe) static var shared = 0
}
