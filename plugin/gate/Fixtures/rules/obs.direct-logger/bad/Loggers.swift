import OSLog

struct Feed {
  let logger = Logger(subsystem: "com.example", category: "feed")
  let qualified = os.Logger(subsystem: "com.example", category: "feed")
  func legacy() { os_log("loaded") }
}
