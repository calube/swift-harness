/// What `xcodebuild test` builds from: a Swift package directory or an Xcode project/workspace.
public enum XcodebuildContainer: Sendable, Equatable {
  /// Absolute package directory; `xcodebuild` runs inside it and uses the package's own schemes.
  case package(directory: String)
  /// Absolute `.xcodeproj` path.
  case project(path: String)
  /// Absolute `.xcworkspace` path.
  case workspace(path: String)
}

/// How swift-snapshot-testing treats references during a run (spec §7.2 rule 4).
public enum SnapshotRecording: String, Sendable, Equatable {
  /// A missing reference fails. Every gate tier runs this way.
  case never
  /// Every reference is rewritten. Only `swiftgate snapshots record` runs this way.
  case all
}

/// One `xcodebuild test` run on a simulator clone.
///
/// The argument list is closed: nothing a caller passes becomes an `xcodebuild` flag, so retry
/// flags that hide flakes (spec §7.2 rule 3) cannot reach it. Retries configured inside a scheme
/// or test plan are caught separately by ``TestRetryConfiguration``.
public struct XcodebuildTestRequest: Sendable, Equatable {
  public static let snapshotRecordVariables = [
    "SNAPSHOT_TESTING_RECORD", "TEST_RUNNER_SNAPSHOT_TESTING_RECORD",
  ]

  /// Flags that rerun or repeat tests. None may appear in ``arguments``.
  public static let refusedFlags: Set<String> = [
    "-retry-tests-on-failure", "-test-iterations", "-run-tests-until-failure",
    "-test-repetition-relaunch-enabled",
  ]

  public let container: XcodebuildContainer
  public let scheme: String
  public let destinationUDID: String
  /// Absolute; per worktree (spec §4.4), never the shared global DerivedData.
  public let derivedDataPath: String
  /// Absolute; must not exist yet.
  public let resultBundlePath: String
  /// `-only-testing:` identifiers (`<Target>` or `<Target>/<Suite>`); empty runs the whole test
  /// action.
  public let onlyTesting: [String]
  public let recording: SnapshotRecording

  public init(
    container: XcodebuildContainer, scheme: String, destinationUDID: String,
    derivedDataPath: String, resultBundlePath: String, onlyTesting: [String] = [],
    recording: SnapshotRecording = .never
  ) {
    self.container = container
    self.scheme = scheme
    self.destinationUDID = destinationUDID
    self.derivedDataPath = derivedDataPath
    self.resultBundlePath = resultBundlePath
    self.onlyTesting = onlyTesting
    self.recording = recording
  }

  public var workingDirectory: String? {
    if case .package(let directory) = container { return directory }
    return nil
  }

  public var arguments: [String] {
    var arguments = ["test", "-quiet"]
    switch container {
    case .package: break
    case .project(let path): arguments += ["-project", path]
    case .workspace(let path): arguments += ["-workspace", path]
    }
    arguments += [
      "-scheme", scheme,
      "-destination", "id=\(destinationUDID)",
      "-derivedDataPath", derivedDataPath,
      "-resultBundlePath", resultBundlePath,
      // Headless builds otherwise fail on "Macro … must be enabled"; macro packages are pinned,
      // so the trust decision was made at pin time (spec §6.2).
      "-skipMacroValidation",
      // The committed pins are the only ones a gate run may trust; without this, an unresolvable
      // pin resolves silently to something else and rewrites `Package.resolved`.
      "-onlyUsePackageVersionsFromResolvedFile",
    ]
    arguments += onlyTesting.map { "-only-testing:\($0)" }
    return arguments
  }

  /// `xcodebuild` forwards `TEST_RUNNER_`-prefixed variables to the test process with the prefix
  /// removed; the unprefixed one covers tools that read the build environment.
  public var environment: [String: String] {
    Dictionary(uniqueKeysWithValues: Self.snapshotRecordVariables.map { ($0, recording.rawValue) })
  }
}

/// The scheme Xcode generates for a package's tests. Observed on Xcode 26.2: a package with more
/// than one product gets `<Package>-Package` (holding every test target); a single-product
/// package gets only its product's scheme, which also holds the tests.
public enum PackageTestScheme {
  public static func name(for package: PackageManifest) -> String {
    let products = package.products.keys.sorted()
    if products.count == 1, let only = products.first { return only }
    return "\(package.name)-Package"
  }
}
