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
    manifests.sorted { $0.path < $1.path }.compactMap { manifest in
      let before: ManifestDeclarations
      switch manifest.atSurface {
      case .unreadable(let reason)?:
        return .unreadable(path: manifest.path, side: .surface, reason: reason)
      case .declared(let declared)?: before = declared
      case nil: before = ManifestDeclarations(targets: [], products: [])
      }
      switch manifest.atHead {
      case .unreadable(let reason)?:
        return .unreadable(path: manifest.path, side: .head, reason: reason)
      case nil:
        return nil
      case .declared(let after):
        let targets = after.targets.subtracting(before.targets).sorted()
        let products = after.products.subtracting(before.products).sorted()
        if targets.isEmpty, products.isEmpty { return nil }
        return .undeclared(path: manifest.path, targets: targets, products: products)
      }
    }
  }

  /// The refusal text: each finding, then the fix.
  public static func message(
    _ findings: [SliceManifestFinding], slice: Int, surface: String, head: String
  ) -> String {
    var undeclared = false
    var unreadable = false
    let listed = findings.map { finding -> String in
      switch finding {
      case .undeclared(let path, let targets, let products):
        undeclared = true
        let named =
          targets.map { "target \($0)" } + products.map { "product \($0)" }
        return "\(path) adds " + joined(named)
      case .unreadable(let path, let side, let reason):
        unreadable = true
        return "\(path) can't be read at \(side == .surface ? surface : head) (\(reason))"
      }
    }
    var message =
      "slice \(slice) at \(head) declares what the surface \(surface) doesn't: "
      + listed.joined(separator: "; ") + "."
    if undeclared {
      message +=
        " At the surface a new target has no sources, so SwiftPM refuses its package and the "
        + "ready gate's prove can't build a test in it or a dependent. Amend the surface with a "
        + "stub for each target and product (its manifest entry and a source file that builds), "
        + "then rebuild the slices on it."
    }
    if unreadable {
      message +=
        " Write each unreadable manifest's targets and products as `.target(name: \"…\")`-style "
        + "elements of the `targets:` and `products:` arrays in its `Package(…)` call."
    }
    return String(message.dropLast())
  }

  /// `a`, `a and b`, `a, b and c`.
  private static func joined(_ items: [String]) -> String {
    guard let last = items.last, items.count > 1 else { return items.first ?? "" }
    return items.dropLast().joined(separator: ", ") + " and " + last
  }
}
