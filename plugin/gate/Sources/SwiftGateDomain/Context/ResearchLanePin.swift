/// What a research lane's `--pin` names. It decides the reuse-cache bucket the pack reads and the
/// `citation.pin` the lane writes. Closed: a pin that fits none of the three shapes fails to parse
/// and names itself, so a mistyped SDK or a truncated sha never lands in the wrong bucket.
public enum ResearchLanePin: Sendable, Equatable {
  /// A git commit, full or abbreviated (7 to 40 hex digits, or 64 in a SHA-256 repository).
  case commit(String)
  /// `<identity>@<version>` from `Package.resolved`.
  case package(identity: String, version: String)
  /// `<platform><version>`, e.g. `iphonesimulator26.2`.
  case sdk(platform: SDKPlatform, version: String)

  public enum SDKPlatform: String, Sendable, Equatable, CaseIterable {
    case iphonesimulator
    case iphoneos
  }

  public enum Kind: String, Sendable, Equatable {
    case commit
    case package
    case sdk

    /// The pin each lane researches at: the codebase lane a commit, the packages and
    /// prior-decisions lanes a package, the Apple docs lane an SDK.
    public static func expected(for lane: ResearchLane) -> Kind {
      switch lane {
      case .codebase: .commit
      case .packages, .priorDecisions: .package
      case .appleDocs: .sdk
      }
    }
  }

  public init(parsing raw: String) throws(ResearchLanePinError) {
    if let at = raw.lastIndex(of: "@") {
      let identity = String(raw[..<at])
      let version = String(raw[raw.index(after: at)...])
      guard Self.isPinComponent(identity), Self.isPinComponent(version), !identity.hasPrefix(".")
      else { throw .unrecognized(raw) }
      self = .package(identity: identity, version: version)
    } else if Self.isCommit(raw) {
      self = .commit(raw)
    } else if let platform = SDKPlatform.allCases.first(where: { raw.hasPrefix($0.rawValue) }),
      Self.isVersion(raw.dropFirst(platform.rawValue.count))
    {
      self = .sdk(platform: platform, version: String(raw.dropFirst(platform.rawValue.count)))
    } else {
      throw .unrecognized(raw)
    }
  }

  public var kind: Kind {
    switch self {
    case .commit: .commit
    case .package: .package
    case .sdk: .sdk
    }
  }

  /// The pin as the command line spelled it.
  public var rawValue: String {
    switch self {
    case .commit(let sha): sha
    case .package(let identity, let version): "\(identity)@\(version)"
    case .sdk(let platform, let version): platform.rawValue + version
    }
  }

  /// The `citation.pin` a claim at this pin carries. An SDK claim holds the bare version, since
  /// `evidence check` compares it with what `xcrun --show-sdk-version` prints.
  public var claimPin: String {
    switch self {
    case .commit, .package: rawValue
    case .sdk(_, let version): version
    }
  }

  private static func isCommit(_ raw: String) -> Bool {
    (7...40).contains(raw.count) || raw.count == 64
      ? raw.allSatisfy { $0.isASCII && $0.isHexDigit } : false
  }

  private static func isVersion(_ raw: Substring) -> Bool {
    let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
    return (1...3).contains(parts.count)
      && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
  }

  private static func isPinComponent(_ raw: String) -> Bool {
    !raw.isEmpty
      && raw.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-+".contains($0)) }
  }
}

public enum ResearchLanePinError: Error, Sendable, Equatable {
  case unrecognized(String)

  public var message: String {
    switch self {
    case .unrecognized(let raw):
      "unrecognized --pin `\(raw)`: expected a commit sha (7 to 40 hex digits, or 64), "
        + "`<package>@<version>`, or an SDK such as `iphonesimulator26.2` or `iphoneos26.2`"
    }
  }
}

/// A `context-pack --key`: the suffix of the pack's file name, so it must stay one path component
/// inside `.harness/context-pack/`. It starts with a letter or digit and holds only letters,
/// digits, `.`, `_` and `-`, which rules out `/`, `..`, a leading `.` and control characters.
public struct ContextPackKey: Sendable, Equatable {
  public let value: String

  public init(parsing raw: String) throws(ContextPackKeyError) {
    guard let first = raw.first, first.isASCII, first.isLetter || first.isNumber,
      raw.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) })
    else { throw .unsafe(raw) }
    value = raw
  }
}

public enum ContextPackKeyError: Error, Sendable, Equatable {
  case unsafe(String)

  public var message: String {
    switch self {
    case .unsafe(let raw):
      "unsafe --key `\(raw)`: a key is one file-name component of letters, digits, `.`, `_` "
        + "and `-`, starting with a letter or digit"
    }
  }
}
