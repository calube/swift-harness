import Foundation

/// One Swift package as `swift package describe --type json` reports it, with every path made
/// repository-relative so it can be matched against changed-file paths from git.
public struct PackageManifest: Sendable, Equatable {
  public let name: String
  /// Repository-relative package directory (no trailing slash).
  public let path: String
  /// Repository-relative directories of the package's local (`path:`) dependencies.
  public let localDependencyPaths: [String]
  /// Product name → the targets it vends.
  public let products: [String: [String]]
  public let targets: [PackageTarget]

  public init(
    name: String, path: String, localDependencyPaths: [String] = [],
    products: [String: [String]] = [:], targets: [PackageTarget]
  ) {
    self.name = name
    self.path = path
    self.localDependencyPaths = localDependencyPaths
    self.products = products
    self.targets = targets
  }

  /// - Parameter repositoryRoot: absolute path the describe output's absolute paths are under.
  public init(describeJSON: Data, repositoryRoot: String) throws(PackageManifestError) {
    let raw: DescribeOutput
    do {
      raw = try JSONDecoder().decode(DescribeOutput.self, from: describeJSON)
    } catch {
      throw .malformedDescription(String(describing: error))
    }
    let path = try Self.relative(raw.path, to: repositoryRoot)
    var localDependencyPaths: [String] = []
    for dependency in raw.dependencies ?? [] where dependency.type == "fileSystem" {
      guard let dependencyPath = dependency.path else {
        throw .malformedDescription("fileSystem dependency '\(dependency.identity)' has no path")
      }
      localDependencyPaths.append(try Self.relative(dependencyPath, to: repositoryRoot))
    }
    self.init(
      name: raw.name,
      path: path,
      localDependencyPaths: localDependencyPaths,
      products: Dictionary(
        (raw.products ?? []).map { ($0.name, $0.targets) }, uniquingKeysWith: { first, _ in first }),
      targets: raw.targets.map { target in
        PackageTarget(
          name: target.name,
          type: PackageTarget.TargetType(rawValue: target.type),
          path: path.isEmpty ? target.path : "\(path)/\(target.path)",
          targetDependencies: target.targetDependencies ?? [],
          productDependencies: target.productDependencies ?? [])
      })
  }

  public func target(named name: String) -> PackageTarget? {
    targets.first { $0.name == name }
  }

  /// Repository-relative path of the package manifest.
  public var manifestPath: String { path.isEmpty ? "Package.swift" : "\(path)/Package.swift" }

  static func relative(_ absolute: String, to root: String) throws(PackageManifestError) -> String {
    let trimmedRoot = root.hasSuffix("/") ? String(root.dropLast()) : root
    let trimmed = absolute.hasSuffix("/") ? String(absolute.dropLast()) : absolute
    if trimmed == trimmedRoot { return "" }
    guard trimmed.hasPrefix(trimmedRoot + "/") else { throw .pathOutsideRepository(absolute) }
    return String(trimmed.dropFirst(trimmedRoot.count + 1))
  }
}

public struct PackageTarget: Sendable, Equatable {
  public enum TargetType: Sendable, Equatable {
    case library
    case executable
    case test
    case macro
    case plugin
    case other(String)

    init(rawValue: String) {
      switch rawValue {
      case "library": self = .library
      case "executable": self = .executable
      case "test": self = .test
      case "macro": self = .macro
      case "plugin": self = .plugin
      default: self = .other(rawValue)
      }
    }
  }

  public let name: String
  public let type: TargetType
  /// Repository-relative source directory.
  public let path: String
  /// Targets in the same package.
  public let targetDependencies: [String]
  /// Product names from dependency packages; describe output does not say which package.
  public let productDependencies: [String]

  public init(
    name: String, type: TargetType, path: String, targetDependencies: [String] = [],
    productDependencies: [String] = []
  ) {
    self.name = name
    self.type = type
    self.path = path
    self.targetDependencies = targetDependencies
    self.productDependencies = productDependencies
  }
}

/// The describe output cannot be trusted to scope work; callers treat every case as `blocked`.
public enum PackageManifestError: Error, Sendable, Equatable {
  case malformedDescription(String)
  case pathOutsideRepository(String)
}

private struct DescribeOutput: Decodable {
  struct Dependency: Decodable {
    let identity: String
    let type: String
    let path: String?
  }
  struct Product: Decodable {
    let name: String
    let targets: [String]
  }
  struct Target: Decodable {
    let name: String
    let type: String
    let path: String
    let targetDependencies: [String]?
    let productDependencies: [String]?

    enum CodingKeys: String, CodingKey {
      case name, type, path
      case targetDependencies = "target_dependencies"
      case productDependencies = "product_dependencies"
    }
  }
  let name: String
  let path: String
  let dependencies: [Dependency]?
  let products: [Product]?
  let targets: [Target]
}
