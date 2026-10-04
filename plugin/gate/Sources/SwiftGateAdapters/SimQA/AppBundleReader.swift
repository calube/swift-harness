import Foundation

/// The app an `xcodebuild build` of the app scheme produced for the simulator.
public struct BuiltApp: Sendable, Equatable {
  /// The `.app` bundle's absolute path.
  public var path: String
  /// Its `CFBundleIdentifier`.
  public var bundleID: String

  public init(path: String, bundleID: String) {
    self.path = path
    self.bundleID = bundleID
  }
}

public enum AppBundleReadError: Error, Sendable, Equatable {
  /// The products folder holds no `.app`.
  case noApp(directory: String)
  /// More than one `.app` could be the scheme's, so none is picked.
  case ambiguous(directory: String, apps: [String])
  /// The bundle's `Info.plist` is missing, unreadable, or has no `CFBundleIdentifier`.
  case unreadable(path: String, reason: String)

  public var message: String {
    switch self {
    case .noApp(let directory): "no .app in \(directory) after the build"
    case .ambiguous(let directory, let apps):
      "several apps in \(directory) (\(apps.joined(separator: ", "))); the app scheme must "
        + "build exactly one"
    case .unreadable(let path, let reason): "\(path): \(reason)"
    }
  }
}

public protocol AppBundleReading: Sendable {
  /// The one app bundle in `productsDirectory`, with its bundle id.
  func builtApp(productsDirectory: String) throws(AppBundleReadError) -> BuiltApp
}

/// Reads the app bundle from a DerivedData products folder.
public struct AppBundleReader: AppBundleReading {
  public init() {}

  /// Where a Debug simulator build of any scheme puts its products.
  public static func productsDirectory(derivedDataPath: String) -> String {
    URL(filePath: derivedDataPath, directoryHint: .isDirectory)
      .appending(path: "Build/Products/Debug-iphonesimulator").path
  }

  /// `-Runner.app` bundles are XCTest's UI test hosts, which a test build leaves beside the app.
  public func builtApp(productsDirectory: String) throws(AppBundleReadError) -> BuiltApp {
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: productsDirectory)) ?? []
    let apps = entries.filter { $0.hasSuffix(".app") && !$0.hasSuffix("-Runner.app") }.sorted()
    guard let app = apps.first else { throw .noApp(directory: productsDirectory) }
    guard apps.count == 1 else { throw .ambiguous(directory: productsDirectory, apps: apps) }
    let bundle = URL(filePath: productsDirectory, directoryHint: .isDirectory)
      .appending(path: app, directoryHint: .isDirectory)
    let plist = bundle.appending(path: "Info.plist")
    let data: Data
    do {
      data = try Data(contentsOf: plist)
    } catch {
      throw .unreadable(path: plist.path, reason: "no readable Info.plist")
    }
    let info = try? PropertyListSerialization.propertyList(from: data, format: nil)
    guard let bundleID = (info as? [String: Any])?["CFBundleIdentifier"] as? String,
      !bundleID.isEmpty
    else { throw .unreadable(path: plist.path, reason: "no CFBundleIdentifier") }
    return BuiltApp(path: bundle.path, bundleID: bundleID)
  }
}
