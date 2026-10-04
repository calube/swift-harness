import ArgumentParser

/// `swiftgate xcode`: edits to an Xcode project the harness doesn't own.
struct XcodeCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "xcode",
    abstract: "Add files to Xcode targets without restructuring the project.",
    subcommands: [XcodeAddFileCommand.self])
}

/// `swiftgate xcode add-file <path> --target <t>`: joins 1 file to 1 target the way the area's
/// inclusion kind says.
struct XcodeAddFileCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "add-file",
    abstract: "Add a source file to an Xcode target.")

  @Argument(help: "The file, repository-relative.")
  var path: String

  @Option(help: "The target that compiles it.")
  var target: String

  @Flag(help: "Print JSON.")
  var json = false

  func run() async throws {
    try StubCommand.notImplemented("xcode add-file", json: json)
  }
}
