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
    let directory = pluginRoot.appending(path: Self.directory, directoryHint: .isDirectory)
    let names: [String]
    do {
      names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    } catch {
      throw ViewerTemplateError(
        "the viewer page's directory \(directory.path) doesn't read: \(error.localizedDescription)")
    }
    func read(_ name: String) throws(ViewerTemplateError) -> String {
      do {
        return try String(contentsOf: directory.appending(path: name), encoding: .utf8)
      } catch {
        throw ViewerTemplateError(
          "the viewer page's \(name) doesn't read: \(error.localizedDescription)")
      }
    }
    func modules(_ suffix: String) throws(ViewerTemplateError) -> [File] {
      var files: [File] = []
      for name in names where name.hasPrefix("run-viewer-") && name.hasSuffix(suffix) {
        files.append(File(name: name, text: try read(name)))
      }
      return files
    }
    return ViewerTemplate(
      html: try read(Anchor.page), stylesheet: try read(Anchor.stylesheet),
      model: try read(Anchor.model), script: try read(Anchor.script),
      moduleScripts: try modules(".js"), moduleStyles: try modules(".css"))
  }

  /// The file names the page loads, and the tags in it the report replaces.
  private enum Anchor {
    static let page = "run-viewer.html"
    static let stylesheet = "run-viewer.css"
    static let model = "run-view-model.js"
    static let script = "run-viewer.js"
    static let stylesheetTag = "<link rel=\"stylesheet\" href=\"\(stylesheet)\">"
    static let modelTag = "<script src=\"\(model)\"></script>"
    static let scriptTag = "<script src=\"\(script)\"></script>"
    static let dataTag = "<script type=\"application/json\" id=\"run-view\"></script>"
  }

  /// 1 self-contained page: the stylesheet and scripts inlined, `viewJSON` embedded.
  public func render(viewJSON: Data) throws(ViewerTemplateError) -> String {
    let styles = [File(name: Anchor.stylesheet, text: stylesheet)] + moduleStyles
    let scripts = [File(name: Anchor.script, text: script)] + moduleScripts
    for file in styles where file.text.range(of: "</style", options: .caseInsensitive) != nil {
      throw ViewerTemplateError("\(file.name) holds `</style`, which would end its inlined block")
    }
    for file in [File(name: Anchor.model, text: model)] + scripts
    where file.text.range(of: "</script", options: .caseInsensitive) != nil {
      throw ViewerTemplateError(
        "\(file.name) holds `</script`, which would end its inlined block")
    }
    let data = ArtifactPageShell.scriptSafe(json: String(decoding: viewJSON, as: UTF8.self))
    let replacements = [
      (Anchor.stylesheetTag, styles.map { "<style>\n\($0.text)\n</style>" }),
      (Anchor.modelTag, ["<script>\n\(model)\n</script>"]),
      (Anchor.scriptTag, scripts.map { "<script>\n\($0.text)\n</script>" }),
      (Anchor.dataTag, ["<script type=\"application/json\" id=\"run-view\">\(data)</script>"]),
    ]
    // Each tag is found in the template alone, so inlined text can't be mistaken for a later tag.
    var found: [(range: Range<String.Index>, text: String)] = []
    for (tag, blocks) in replacements {
      let ranges = html.ranges(of: tag)
      guard ranges.count == 1, let range = ranges.first else {
        throw ViewerTemplateError(
          "\(Anchor.page) holds `\(tag)` \(ranges.count) times; the report replaces it once")
      }
      found.append((range, blocks.joined(separator: "\n")))
    }
    var page = ""
    var cursor = html.startIndex
    for (range, text) in found.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
      page += html[cursor..<range.lowerBound]
      page += text
      cursor = range.upperBound
    }
    page += html[cursor...]
    return page
  }
}
