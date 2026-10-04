import Foundation
import SwiftGateDomain

/// Why the viewer page couldn't be read or assembled.
public struct ViewerTemplateError: Error, Sendable, Equatable, CustomStringConvertible {
  public let description: String

  public init(_ description: String) { self.description = description }
}

/// The run viewer page from the plugin's `viewer/`: its HTML, stylesheet, both core scripts and
/// every optional `run-viewer-*` module present.
public struct ViewerTemplate: Sendable, Equatable {
  /// Relative to the plugin root.
  public static let directory = "viewer"

  public struct File: Sendable, Equatable {
    public let name: String
    public let text: String

    public init(name: String, text: String) {
      self.name = name
      self.text = text
    }
  }

  public var html: String
  public var stylesheet: String
  public var model: String
  public var script: String
  /// `run-viewer-*.js`, in name order.
  public var moduleScripts: [File]
  /// `run-viewer-*.css`, in name order.
  public var moduleStyles: [File]

  public init(
    html: String, stylesheet: String, model: String, script: String,
    moduleScripts: [File] = [], moduleStyles: [File] = []
  ) {
    self.html = html
    self.stylesheet = stylesheet
    self.model = model
    self.script = script
    self.moduleScripts = moduleScripts
    self.moduleStyles = moduleStyles
  }

  /// Reads `viewer/` under `pluginRoot`.
  public static func load(pluginRoot: URL) throws(ViewerTemplateError) -> ViewerTemplate {
    throw ViewerTemplateError("not implemented")
  }

  /// 1 self-contained page: the stylesheet and scripts inlined, `viewJSON` embedded.
  public func render(viewJSON: Data) throws(ViewerTemplateError) -> String {
    html
  }
}
