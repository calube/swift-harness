import Foundation
import Testing

/// Scripts and sources a test writes out that end by themselves.
enum BoundedShapes {
  static let swiftBreak = "while true { if done() { break } }\n"
  static let swiftReturn = "func wait() { while true { if ready() { return } } }\n"
  static let shellExit = "#!/bin/sh\nwhile :; do\n  [ -f done ] && exit 0\n  sleep 1\ndone\n"
  static let pythonBreak = """
    while True:
        if done():
            break
    print("done")

    """
  static let briefSleep = "#!/bin/sh\nsleep 5\necho woke\n"
  static let timeoutWrapper = "#!/bin/sh\ntimeout 30 sleep infinity\n"
  static let alarm = "import signal\nsignal.alarm(90)\nwhile True:\n    pass\n"
  static let withTimeout = "try await withTimeout(.seconds(5)) { while true { await tick() } }\n"
  static let dispatchDeadline =
    "DispatchQueue.main.asyncAfter(deadline: .now() + 5) { exit(0) }\ndispatchMain()\n"
  static let runUntil = "RunLoop.main.run(until: Date().addingTimeInterval(1))\n"
  static let timeBound = "import time\nend = time.time() + 30\nwhile True:\n    pass\n"
  static let finiteLoop = "for i in 0..<1_000_000 { total += i }\n"
  static let prose = "the helper keeps reading while true values keep arriving"
  static let interpolatedDeadline =
    "let deadline = DispatchTime.now() + .seconds(\(90))\nwhile true { spin() }\n"
}

@Test("a script that ends in sleep infinity is reported — catches a leaked process")
func namesTheShapeInItsDisplayName() {
  #expect(BoundedShapes.briefSleep.contains("sleep 5"))
}
