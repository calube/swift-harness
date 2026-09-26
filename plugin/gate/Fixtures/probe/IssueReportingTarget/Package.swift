// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "IssueReportingTarget",
  platforms: [.iOS(.v18), .macOS(.v15)],
  products: [.library(name: "IssueReportingTarget", targets: ["IssueReportingTarget"])],
  dependencies: [
    .package(path: "../HostTarget"),
    .package(
      url: "https://github.com/pointfreeco/swift-composable-architecture",
      exact: "1.26.2",
      traits: ["ComposableArchitecture2Deprecations"]
    ),
    .package(url: "https://github.com/pointfreeco/swift-issue-reporting", exact: "1.8.1"),
  ],
  targets: [
    .target(
      name: "IssueReportingTarget",
      dependencies: [
        .product(name: "HostTarget", package: "HostTarget"),
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
        .product(name: "IssueReporting", package: "swift-issue-reporting"),
      ]
    )
  ],
  swiftLanguageModes: [.v6]
)
