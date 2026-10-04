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
    ""
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
    ""
  }

  public func builtApp(productsDirectory: String) throws(AppBundleReadError) -> BuiltApp {
    throw .noApp(directory: productsDirectory)
  }
}
