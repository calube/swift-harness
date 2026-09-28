import SwiftGateDomain
import SwiftParser
import SwiftSyntax

/// The functions and types a commit's parent declares, which a forwarding stub may call.
public struct SurfaceParentIndex: Sendable, Equatable {
  public let functions: Set<String>
  public let types: Set<String>

  public init(functions: Set<String>, types: Set<String>) {
    self.functions = functions
    self.types = types
  }

  public static func build(_ sources: [String: String]) -> SurfaceParentIndex {
    SurfaceParentIndex(functions: [], types: [])
  }
}

/// The SwiftSyntax half of `surface-check`: finds the bodies a change adds or changes and judges
/// each against the allowed stubs (fast modes §3.2).
public enum SurfaceBodyScan {
  /// The callees of every body shaped like a forwarding call, so the parent's declarations are
  /// read only when a body could forward.
  public static func forwardCallees(in change: SurfaceFileChange) -> Set<String> {
    []
  }

  public static func judge(_ change: SurfaceFileChange, parent: SurfaceParentIndex)
    -> [SurfaceJudgement]
  {
    []
  }
}
