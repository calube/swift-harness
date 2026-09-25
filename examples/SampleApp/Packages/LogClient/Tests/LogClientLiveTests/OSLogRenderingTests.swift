import LogClient
import OSLog
import Testing

@testable import LogClientLive

struct OSLogRenderingTests {
  @Test("attributes are split by privacy tag — catches a private or sensitive value leaking into the public log segment")
  func partitionsByPrivacy() {
    let segments = OSLogRendering.segments(for: [
      .public("attempt", 3),
      .private("email", "a@b.c"),
      .sensitive("token", "s3cr3t"),
    ])

    #expect(segments.publicText == "attempt=3")
    #expect(segments.privateText == "email=a@b.c")
    #expect(segments.sensitiveText == "token=s3cr3t")
  }

  @Test("log levels map to OSLog types — catches errors being filed as debug noise in Console")
  func levelMapping() {
    #expect(OSLogRendering.type(for: .debug) == .debug)
    #expect(OSLogRendering.type(for: .info) == .info)
    #expect(OSLogRendering.type(for: .notice) == .default)
    #expect(OSLogRendering.type(for: .error) == .error)
    #expect(OSLogRendering.type(for: .fault) == .fault)
  }

  @Test("the minimum level gates lower severities only — catches debug logs shipping in release or errors being dropped")
  func minimumLevelGate() {
    let client = LogClient.osLog(subsystem: "test", minimumLevel: .notice)
    #expect(client.isEnabled(.info, "Any") == false)
    #expect(client.isEnabled(.notice, "Any"))
    #expect(client.isEnabled(.fault, "Any"))
  }
}
