import Foundation

/// Build settings from `swift package dump-package`, which `describe` does not report.
public struct PackageSettings: Sendable, Equatable {
  /// Target name → the default actor isolation its manifest sets (`MainActor`, `nonisolated`),
  /// for targets that set one via `.defaultIsolation(_:)` or `-default-isolation` unsafe flags.
  public let defaultIsolation: [String: String]

  public init(defaultIsolation: [String: String] = [:]) {
    self.defaultIsolation = defaultIsolation
  }

  public init(dumpPackageJSON: Data) throws(PackageManifestError) {
    let raw: DumpOutput
    do {
      raw = try JSONDecoder().decode(DumpOutput.self, from: dumpPackageJSON)
    } catch {
      throw .malformedDescription(String(describing: error))
    }
    var isolation: [String: String] = [:]
    for target in raw.targets {
      for setting in target.settings ?? [] where setting.tool == "swift" {
        if let value = setting.kind.defaultIsolation?.value {
          isolation[target.name] = value
        } else if let flags = setting.kind.unsafeFlags?.value,
          let index = flags.firstIndex(of: "-default-isolation"), index + 1 < flags.count
        {
          isolation[target.name] = flags[index + 1]
        }
      }
    }
    self.init(defaultIsolation: isolation)
  }
}

private struct DumpOutput: Decodable {
  struct Target: Decodable {
    let name: String
    let settings: [Setting]?
  }
  struct Setting: Decodable {
    let tool: String
    let kind: Kind
  }
  /// Swift encodes enum payloads as `{"case": {"_0": value}}`; only the cases read here decode.
  struct Kind: Decodable {
    let defaultIsolation: Payload<String>?
    let unsafeFlags: Payload<[String]>?
  }
  struct Payload<Value: Decodable>: Decodable {
    let value: Value
    enum CodingKeys: String, CodingKey { case value = "_0" }
  }
  let targets: [Target]
}
