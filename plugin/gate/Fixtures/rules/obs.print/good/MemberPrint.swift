struct Document {
  let printer: Printer
  let hint = "print(items) is banned outside LogClientLive"
  func send() { printer.print(self) }
}
