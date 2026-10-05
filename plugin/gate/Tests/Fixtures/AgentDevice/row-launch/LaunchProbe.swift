import SwiftUI

/// Appends each launch's arguments to `Documents/launches.log`, so a capture reads every launch.
@main
struct LaunchProbeApp: App {
  private let arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())

  init() {
    let line = "launch: [" + arguments.joined(separator: " ") + "]\n"
    let log = URL.documentsDirectory.appending(path: "launches.log")
    if let handle = try? FileHandle(forWritingTo: log) {
      handle.seekToEndOfFile()
      handle.write(Data(line.utf8))
      try? handle.close()
    } else {
      try? Data(line.utf8).write(to: log)
    }
  }

  var body: some Scene {
    WindowGroup {
      Text(arguments.isEmpty ? "live" : arguments.joined(separator: " "))
        .accessibilityIdentifier("probe.arguments")
    }
  }
}
