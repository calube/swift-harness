import ComposableArchitecture

enum Legacy {
  static func effects(_ send: Send<Action>) -> Effect<Action> {
    .run { send in await send(.response(TaskResult { try await load() })) }
  }
  static var debounced: Effect<Action> {
    .run { _ in }.debounce(id: SearchID.self, for: 0.3, scheduler: DispatchQueue.main)
  }
  static var throttled: Effect<Action> {
    Effect.send(.tick).throttle(id: TickID.self, for: 1, scheduler: DispatchQueue.main, latest: true)
  }
  static var animated: Effect<Action> { .send(.shown).animation(.default) }
  static var transacted: Effect<Action> { .send(.shown).transaction(Transaction()) }
  static var sequence: Effect<Action> { .concatenate(.send(.a), .send(.b)) }
  static var mapped: Effect<Action> { .run { _ in }.map(Action.child) }
}
