enum Route {
  case home, settings

  init(path: String) {
    switch path {
    case "home": self = .home
    case "settings": self = .settings
    default: fatalError("unknown route \(path)")
    }
  }

  func unreachable() -> Never { preconditionFailure() }
  func qualified() -> Never { Swift.fatalError("boom") }
}
