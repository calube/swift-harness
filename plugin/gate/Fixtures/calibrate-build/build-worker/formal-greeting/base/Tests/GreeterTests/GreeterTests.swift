import Greeter
import Testing

@Test("greets by name — catches a greeting that drops the name")
func greetsByName() {
  #expect(Greeter.greet("Ada") == "Hello, Ada")
}
