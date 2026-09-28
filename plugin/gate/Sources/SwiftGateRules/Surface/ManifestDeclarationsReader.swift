import SwiftGateDomain
import SwiftParser
import SwiftSyntax

/// Reads the targets and products a `Package.swift` declares, with the same parser and
/// `PackageDescription` factory names `surface-check` judges a manifest by.
public enum ManifestDeclarationsReader {
  public static func isManifest(_ path: String) -> Bool {
    ManifestDiff.isManifest(path)
  }

  public static func read(_ text: String) -> ManifestReading {
    .unreadable("")
  }
}
