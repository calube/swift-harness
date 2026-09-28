/// The targets and products 1 `Package.swift` declares by name.
public struct ManifestDeclarations: Sendable, Equatable {
  /// Every target but test targets. A test target holds only tests, which `prove` keeps at the
  /// proof base, so a slice may add one.
  public let targets: Set<String>
  public let products: Set<String>

  public init(targets: Set<String>, products: Set<String>) {
    self.targets = targets
    self.products = products
  }
}

/// What reading 1 manifest's declarations gave.
public enum ManifestReading: Sendable, Equatable {
  case declared(ManifestDeclarations)
  /// Why the declarations couldn't be read, which is never evidence that nothing was added.
  case unreadable(String)
}

/// 1 `Package.swift` that differs between the sprint's surface and a slice's HEAD.
public struct SliceManifest: Sendable, Equatable {
  /// Toplevel-relative.
  public let path: String
  /// `nil` when the surface has no manifest there: the slice adds the package.
  public let atSurface: ManifestReading?
  /// `nil` when the slice deletes the manifest.
  public let atHead: ManifestReading?

  public init(path: String, atSurface: ManifestReading?, atHead: ManifestReading?) {
    self.path = path
    self.atSurface = atSurface
    self.atHead = atHead
  }
}

/// Why a slice's manifests stop `sprint slice`.
public enum SliceManifestFinding: Sendable, Equatable {
  /// Targets and products the slice declares that the surface doesn't, each sorted.
  case undeclared(path: String, targets: [String], products: [String])
  case unreadable(path: String, side: Side, reason: String)

  public enum Side: Sendable, Equatable {
    case surface
    case head
  }
}

/// A slice may fill the targets the surface declares but never declare one. At the surface a new
/// target has no sources, so SwiftPM refuses its package, and every test in it or a dependent is
/// `prove.compile-only` at the sprint's `ready` gate.
public enum SliceManifestCheck {
  public static func findings(_ manifests: [SliceManifest]) -> [SliceManifestFinding] {
    []
  }

  /// The refusal text: each finding, then the fix.
  public static func message(
    _ findings: [SliceManifestFinding], slice: Int, surface: String, head: String
  ) -> String {
    ""
  }
}
