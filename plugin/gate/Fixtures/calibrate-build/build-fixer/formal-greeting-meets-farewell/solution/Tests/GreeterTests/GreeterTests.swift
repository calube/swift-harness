import Greeter
import Testing

@Test("greets by name — catches a greeting that drops the name")
func greetsByName() {
  #expect(Greeter.greet("Ada") == "Hello, Ada")
}

@Test("says goodbye by name — catches a farewell that drops the name")
func farewellByName() {
  #expect(Greeter.farewell("Ada") == "Goodbye, Ada")
}

@Test("a formal greeting says good day — catches the informal greeting used for both")
func formalGreeting() {
  #expect(Greeter.greet("Ada", formal: true) == "Good day, Ada.")
}

@Test("an informal greeting is the plain one — catches the formal greeting used for both")
func informalGreeting() {
  #expect(Greeter.greet("Ada", formal: false) == "Hello, Ada")
}
