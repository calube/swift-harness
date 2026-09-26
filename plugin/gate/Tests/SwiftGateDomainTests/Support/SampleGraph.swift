import SwiftGateDomain
import SwiftGateTestSupport

enum SampleGraph {
  static let packagesRoot = "examples/SampleApp/Packages"
  static let app = AppModule(name: "SampleApp", path: "examples/SampleApp/App")

  static func manifests() throws -> [PackageManifest] {
    try Fixture.samplePackages.map {
      try PackageManifest(
        describeJSON: Fixture.describe($0), repositoryRoot: Fixture.repositoryRoot)
    }
  }

  static func graph(config: Config? = nil) throws -> ModuleGraph {
    try ModuleGraph(packages: manifests(), apps: [app], config: config)
  }

  static func config(modules: [ModuleOverride]) throws -> Config {
    try Config(
      xcode: "26.2", appScheme: "SampleApp", packages: ["\(packagesRoot)/*"],
      simulator: SimulatorConfig(device: "iPhone 17", os: "26.2"), modules: modules)
  }
}
