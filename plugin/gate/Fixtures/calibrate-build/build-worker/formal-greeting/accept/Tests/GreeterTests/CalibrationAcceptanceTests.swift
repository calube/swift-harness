import Greeter
import Testing

@Suite struct CalibrationAcceptance {
  @Test func formalGreeting() {
    #expect(Greeter.greet("Grace", formal: true) == "Good day, Grace.")
  }

  @Test func informalGreeting() {
    #expect(Greeter.greet("Grace", formal: false) == "Hello, Grace")
  }

  @Test func plainGreetingUnchanged() {
    #expect(Greeter.greet("Grace") == "Hello, Grace")
  }
}
