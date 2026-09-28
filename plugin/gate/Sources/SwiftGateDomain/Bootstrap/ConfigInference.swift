import Foundation

/// `xcodebuild -list -json` for a project or workspace.
public struct SchemeListing: Sendable, Equatable {
  /// The project's or workspace's name.
  public let container: String
  public let schemes: [String]
  /// Empty for a workspace, whose listing has no targets.
  public let targets: [String]

  public init(container: String, schemes: [String], targets: [String]) {
    self.container = container
    self.schemes = schemes
    self.targets = targets
  }

  public static func decode(_ data: Data) throws -> SchemeListing {
    let wire = try JSONDecoder().decode(Wire.self, from: data)
    guard let body = wire.project ?? wire.workspace else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: [], debugDescription: "neither a project nor a workspace listing"))
    }
    return SchemeListing(
      container: body.name, schemes: body.schemes ?? [], targets: body.targets ?? [])
  }

  private struct Wire: Decodable {
    struct Body: Decodable {
      let name: String
      let schemes: [String]?
      let targets: [String]?
    }

    let project: Body?
    let workspace: Body?
  }
}

/// What `bootstrap` learned about a repository and the machine to write its first config.
public struct RepositorySurvey: Sendable, Equatable {
  /// Repository-relative directories holding a `Package.swift` (`""` is the root).
  public var packageDirectories: [String]
  /// `nil` when the root has no single app container, or listing it failed.
  public var schemes: SchemeListing?
  /// `26.2`, from `xcodebuild -version`.
  public var xcodeVersion: String?
  public var devices: [SimulatorDevice]

  public init(
    packageDirectories: [String], schemes: SchemeListing?, xcodeVersion: String?,
    devices: [SimulatorDevice]
  ) {
    self.packageDirectories = packageDirectories
    self.schemes = schemes
    self.xcodeVersion = xcodeVersion
    self.devices = devices
  }
}

public struct InferredSimulator: Sendable, Equatable {
  public let device: String
  public let os: String

  public init(device: String, os: String) {
    self.device = device
    self.os = os
  }
}

/// The `.swiftgate.toml` values inferred from a ``RepositorySurvey``. A value that could not be
/// inferred renders as ``InferredConfig/placeholder`` and is listed in ``unresolved``, so the gap
/// is visible instead of guessed.
public struct InferredConfig: Sendable, Equatable {
  public static let placeholder = "SET-ME"

  public let xcode: String?
  public let appScheme: String?
  public let packages: [String]
  public let simulator: InferredSimulator?
  /// The package directories the globs were built from.
  public let packageDirectories: [String]
  /// Installed iOS simulator devices, to check an existing config's pin against.
  public let availableDevices: [InferredSimulator]

  public var unresolved: [String] {
    var notes: [String] = []
    if xcode == nil { notes.append("xcode: `xcodebuild -version` gave no version") }
    if appScheme == nil {
      notes.append("app_scheme: no single .xcodeproj/.xcworkspace at the root to list schemes from")
    }
    if packages.isEmpty { notes.append("packages: no directory with a Package.swift was found") }
    if simulator == nil { notes.append("simulator: no available iPhone simulator is installed") }
    return notes
  }

  /// Fills the template's `{{XCODE}}`, `{{APP_SCHEME}}`, `{{PACKAGES}}`, `{{DEVICE}}`, `{{OS}}`
  /// and `{{PROFILE}}`, which is `profile` or ``Config/defaultProfile``.
  public func render(template: String, profile: String? = nil) -> String {
    let packageList =
      packages.isEmpty
      ? "[\(quoted(Self.placeholder))]" : "[\(packages.map(quoted).joined(separator: ", "))]"
    return
      template
      .replacingOccurrences(of: "{{XCODE}}", with: quoted(xcode ?? Self.placeholder))
      .replacingOccurrences(of: "{{APP_SCHEME}}", with: quoted(appScheme ?? Self.placeholder))
      .replacingOccurrences(of: "{{PACKAGES}}", with: packageList)
      .replacingOccurrences(of: "{{DEVICE}}", with: quoted(simulator?.device ?? Self.placeholder))
      .replacingOccurrences(of: "{{OS}}", with: quoted(simulator?.os ?? Self.placeholder))
      .replacingOccurrences(of: "{{PROFILE}}", with: quoted(profile ?? Config.defaultProfile))
  }

  /// Where an existing config disagrees with the repository or the machine. Only disagreements
  /// that break a run are reported: a config may legitimately differ from the defaults.
  public func drift(from config: Config) -> [String] {
    var notes: [String] = []
    if let xcode, !Doctor.matchesPin(installed: xcode, pin: config.xcode) {
      notes.append("xcode is \"\(config.xcode)\"; the selected Xcode is \(xcode)")
    }
    let uncovered = packageDirectories.filter { directory in
      !config.packages.contains { PackageGlob.matches($0, directory) }
    }
    if !uncovered.isEmpty {
      notes.append(
        "packages does not cover \(uncovered.map { $0.isEmpty ? "." : $0 }.joined(separator: ", "))"
      )
    }
    if let appScheme, config.appScheme != appScheme {
      notes.append(
        "app_scheme is \"\(config.appScheme)\"; the app container's scheme is \(appScheme)")
    }
    let pinned = InferredSimulator(device: config.simulator.device, os: config.simulator.os)
    if !availableDevices.isEmpty,
      !availableDevices.contains(where: {
        $0.device == pinned.device && Doctor.matchesPin(installed: $0.os, pin: pinned.os)
      })
    {
      let suggestion = simulator.map { " (\($0.device), iOS \($0.os) is)" } ?? ""
      notes.append(
        "simulator \(pinned.device), iOS \(pinned.os) is not installed\(suggestion)")
    }
    return notes
  }

  private func quoted(_ value: String) -> String {
    "\""
      + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
        of: "\"", with: "\\\"") + "\""
  }
}

public enum ConfigInference {
  public static func infer(_ survey: RepositorySurvey) -> InferredConfig {
    let iPhones = survey.devices.compactMap { device -> InferredSimulator? in
      guard device.isAvailable, device.name.hasPrefix("iPhone"),
        let runtime = device.runtime, runtime.platform == "iOS"
      else { return nil }
      return InferredSimulator(device: device.name, os: runtime.version)
    }
    return InferredConfig(
      xcode: survey.xcodeVersion, appScheme: survey.schemes.flatMap(appScheme),
      packages: packageGlobs(survey.packageDirectories),
      simulator: simulator(among: iPhones, xcodeVersion: survey.xcodeVersion),
      packageDirectories: survey.packageDirectories.sorted(), availableDevices: iPhones)
  }

  /// A parent holding two or more packages becomes `parent/*`; any other package is listed by
  /// path, and the root package is `.`.
  public static func packageGlobs(_ directories: [String]) -> [String] {
    var byParent: [String: [String]] = [:]
    for directory in directories where !directory.isEmpty {
      let parent = directory.split(separator: "/").dropLast().joined(separator: "/")
      byParent[parent, default: []].append(directory)
    }
    var globs: [String] = directories.contains("") ? ["."] : []
    for (parent, children) in byParent.sorted(by: { $0.key < $1.key }) {
      if children.count >= 2 {
        globs.append(parent.isEmpty ? "*" : "\(parent)/*")
      } else {
        globs += children
      }
    }
    return globs
  }

  /// The scheme named after its container, else the one app-looking target scheme.
  public static func appScheme(_ listing: SchemeListing) -> String? {
    if listing.schemes.contains(listing.container) { return listing.container }
    let targetSchemes = listing.schemes.filter {
      listing.targets.contains($0) && !$0.hasSuffix("Tests")
    }
    return targetSchemes.count == 1 ? targetSchemes.first : nil
  }

  /// The base-model iPhone (`iPhone 17` over `iPhone 17 Pro`, newest generation first) on the
  /// runtime matching the selected Xcode's major.minor, else on the newest iOS runtime. Every
  /// machine with that Xcode can install its own runtime; a newer one is a per-machine extra, and
  /// snapshot references recorded on it fail everywhere else.
  static func simulator(among iPhones: [InferredSimulator], xcodeVersion: String?)
    -> InferredSimulator?
  {
    let matchingXcode = xcodeVersion.map { xcode in
      iPhones.filter { majorMinor($0.os) == majorMinor(xcode) }
    }
    let candidates = matchingXcode.flatMap { $0.isEmpty ? nil : $0 } ?? iPhones
    guard let newest = candidates.map({ ToolVersion($0.os) }).max() else { return nil }
    let onNewest = candidates.filter { ToolVersion($0.os) == newest }
    func generation(_ name: String) -> Int? {
      let parts = name.split(separator: " ")
      guard parts.count == 2 else { return nil }
      return Int(parts[1])
    }
    if let base = onNewest.filter({ generation($0.device) != nil })
      .max(by: { (generation($0.device) ?? 0) < (generation($1.device) ?? 0) })
    {
      return base
    }
    return onNewest.min { $0.device < $1.device }
  }

  private static func majorMinor(_ version: String) -> [Int] {
    Array(ToolVersion(version).components.prefix(2))
  }
}

/// `.swiftgate.toml` `packages` glob matching, segment by segment as `PackageDirectories` expands
/// them: `*` and `?` stay within one segment and `.` segments are ignored.
enum PackageGlob {
  static func matches(_ glob: String, _ directory: String) -> Bool {
    let pattern = glob.split(separator: "/").map(String.init).filter { $0 != "." }
    let path = directory.split(separator: "/").map(String.init)
    guard pattern.count == path.count else { return false }
    return zip(pattern, path).allSatisfy { fnmatch($0, $1, 0) == 0 }
  }
}
