import Probe
import Testing

@Suite struct SharedFirstLineTests {
  @Test func firstMismatch() {
    Issue.record("State does not match.\n  count: expected 1, actual \(double(1))")
  }

  @Test func secondMismatch() {
    Issue.record("State does not match.\n  count: expected 3, actual \(double(2))")
  }
}
