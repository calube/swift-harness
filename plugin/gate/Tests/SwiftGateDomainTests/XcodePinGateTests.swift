import SwiftGateDomain
import Testing

@Suite("xcode pin gate")
struct XcodePinGateTests {
  @Test(
    "a pin the selected Xcode does not match is BLOCKED with the fix named — catches a build under the wrong toolchain reported as failing tests"
  )
  func mismatch() {
    let message = XcodePinGate.message(installed: "26.2", pin: "25.0")
    #expect(message?.contains("26.2") == true)
    #expect(message?.contains("25.0") == true)
    #expect(message?.contains("xcode-select") == true)
  }

  @Test(
    "a pin matched by prefix (a patch of the pinned minor) never blocks — catches the pin check comparing full strings instead of Doctor.matchesPin"
  )
  func patchMatches() {
    #expect(XcodePinGate.message(installed: "26.2.1", pin: "26.2") == nil)
  }

  @Test("no pin configured never blocks — catches a blank pin treated as a mismatch")
  func noPin() {
    #expect(XcodePinGate.message(installed: "25.0", pin: "") == nil)
    #expect(XcodePinGate.message(installed: nil, pin: "") == nil)
  }

  @Test(
    "an unreadable Xcode version is BLOCKED, the same as Doctor treats it — catches a pin check that lets an unreadable machine pass"
  )
  func unreadable() {
    let message = XcodePinGate.message(installed: nil, pin: "26.2")
    #expect(message?.contains("xcodebuild -version") == true)
    #expect(message?.contains("xcode-select -p") == true)
  }
}
