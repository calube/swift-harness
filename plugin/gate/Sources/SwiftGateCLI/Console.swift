/// The CLI's one writer to stdout: its reports are the product, not diagnostics to log.
enum Console {
  static func write(_ text: String) {
    print(text)  // swiftgate:allow obs.print — the report on stdout is the CLI's output
  }
}
