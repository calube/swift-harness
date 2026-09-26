import ArgumentParser
import SwiftGateDomain

/// Shared by every command that produces a ``RunReport``.
struct OutputOptions: ParsableArguments {
  @Flag(help: "Print the full versioned JSON report instead of the capped human summary.")
  var json = false

  var format: OutputFormat { json ? .json : .human }
}
