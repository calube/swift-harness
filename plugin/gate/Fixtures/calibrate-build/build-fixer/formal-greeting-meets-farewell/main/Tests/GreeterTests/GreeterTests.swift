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
