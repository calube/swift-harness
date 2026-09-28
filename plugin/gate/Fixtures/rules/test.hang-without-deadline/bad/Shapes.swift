import Foundation
import Testing

/// Scripts and sources a test writes out that never end by themselves.
enum HangingShapes {
  static let swiftSpin = "public func answer() -> Int { while true { counter += 1 } }\n"
  static let cSpin = "int main(void) { for (;;) { work(); } }\n"
  static let repeatSpin = "repeat { poll() } while true\n"
  static let shellColon = "#!/bin/sh\nwhile :; do echo tick; done\n"
  static let shellTrue = """
    #!/bin/sh
    while true
    do
      sleep 1
    done

    """
  static let python = """
    import time
    while True:
        time.sleep(1)

    """
  static let sleepForever = "#!/bin/sh\nsleep infinity\n"
  static let runLoop = "import Foundation\nRunLoop.main.run()\n"
  static let dispatch = "import Dispatch\ndispatchMain()\n"
  static let signalPause = "import signal\nsignal.pause()\n"
  static let innerBreakOnly = """
    while true {
      for item in items { if item.isEmpty { break } }
    }

    """
}
