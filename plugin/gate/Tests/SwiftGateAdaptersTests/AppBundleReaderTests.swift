import Foundation
import SwiftGateAdapters
import SwiftGateTestSupport
import Testing

@Suite("AppBundleReader")
struct AppBundleReaderTests {
  let products = TestTemporaryDirectory.root.appending(
    path: "app-bundle-\(UUID().uuidString)/Build/Products/Debug-iphonesimulator",
    directoryHint: .isDirectory)

  func makeApp(_ name: String, info: [String: Any]?) throws {
    let bundle = products.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    if let info {
      let data = try PropertyListSerialization.data(
        fromPropertyList: info, format: .binary, options: 0)
      try data.write(to: bundle.appending(path: "Info.plist"))
    }
  }

  func read() -> Result<BuiltApp, AppBundleReadError> {
    Result { () throws(AppBundleReadError) in
      try AppBundleReader().builtApp(productsDirectory: products.path)
    }
  }

  @Test(
    "the one app in the products folder yields its path and CFBundleIdentifier, beside a UI test runner — catches the bundle id guessed from the scheme name"
  )
  func readsTheApp() throws {
    try makeApp("Sample App.app", info: ["CFBundleIdentifier": "com.example.SampleApp"])
    try makeApp("SampleAppUITests-Runner.app", info: ["CFBundleIdentifier": "com.example.Runner"])
    try FileManager.default.createDirectory(
      at: products.appending(path: "SampleKit.framework"), withIntermediateDirectories: true)

    let app = try read().get()

    #expect(app.bundleID == "com.example.SampleApp")
    #expect(app.path == products.appending(path: "Sample App.app").path)
  }

  @Test(
    "no app, two apps, or an app without a bundle id each fail naming the folder or bundle — catches an install of the wrong app or of nothing"
  )
  func refusesWhatIsNotOneApp() throws {
    guard case .failure(.noApp(let directory)) = read() else {
      Issue.record("an empty products folder read as an app")
      return
    }
    #expect(directory == products.path)

    try makeApp("One.app", info: ["CFBundleName": "One"])
    guard case .failure(.unreadable(let path, _)) = read() else {
      Issue.record("an app without CFBundleIdentifier read as an app")
      return
    }
    #expect(path.hasSuffix("One.app/Info.plist"))

    try makeApp("Two.app", info: ["CFBundleIdentifier": "com.example.Two"])
    guard case .failure(.ambiguous(_, let apps)) = read() else {
      Issue.record("two apps read as one")
      return
    }
    #expect(apps == ["One.app", "Two.app"])
    #expect(AppBundleReadError.ambiguous(directory: "/p", apps: apps).message.contains("Two.app"))
  }

  @Test(
    "the products folder is DerivedData's Debug-iphonesimulator products — catches a reader looking where a simulator build never writes"
  )
  func productsDirectory() {
    #expect(
      AppBundleReader.productsDirectory(derivedDataPath: "/dd")
        == "/dd/Build/Products/Debug-iphonesimulator")
  }
}
