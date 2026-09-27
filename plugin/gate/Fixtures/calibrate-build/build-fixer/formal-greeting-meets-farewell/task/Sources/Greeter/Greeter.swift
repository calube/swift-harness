public enum Greeter {
  public static func greet(_ name: String) -> String {
    "Hello, \(name)"
  }

  public static func greet(_ name: String, formal: Bool) -> String {
    formal ? "Good day, \(name)." : greet(name)
  }
}
