import Testing

enum Scripts {
  static let carriageReturns = "echo start\rwhile :; do :; done"
  static let rawPythonString = "exec(r\"while True: pass\")"
}
