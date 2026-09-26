import Foundation
import SwiftGateDomain

/// Reads `.swiftgate.toml` from a repository root.
public struct ConfigLoader: Sendable {
  public static let fileName = Config.fileName

  private let decoder: any ConfigDecoding

  public init(decoder: any ConfigDecoding = TOMLConfigDecoder()) {
    self.decoder = decoder
  }

  /// Returns `nil` when the repository has no config: swift-harness is not enabled there, and
  /// hooks must be no-ops.
  public func load(repositoryRoot: URL) throws(ConfigLoadError) -> Config? {
    let file = repositoryRoot.appending(path: Self.fileName, directoryHint: .notDirectory)
    let data: Data
    do {
      data = try Data(contentsOf: file)
    } catch CocoaError.fileReadNoSuchFile {
      return nil
    } catch {
      throw .unreadable(path: file.path, reason: error.localizedDescription)
    }
    guard let text = String(data: data, encoding: .utf8) else {
      throw .unreadable(path: file.path, reason: "not valid UTF-8")
    }
    return try decoder.decode(text)
  }
}
