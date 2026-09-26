import OSLog

struct Feed {
  let signposter = OSSignposter()
  let named = OSSignposter(subsystem: "com.example", category: "feed")
  func mark(_ log: OSLog) { os_signpost(.event, log: log, name: "feed") }
}
