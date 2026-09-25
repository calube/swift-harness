import Foundation

/// The one escaping function every rendered page uses. Its output is safe both as element text
/// and inside a double-quoted attribute, so no caller has to pick a context-specific variant.
public enum HTMLEscape {
  public static func escape(_ text: String) -> String {
    var result = ""
    result.reserveCapacity(text.utf8.count)
    for character in text {
      switch character {
      case "&": result += "&amp;"
      case "<": result += "&lt;"
      case ">": result += "&gt;"
      case "\"": result += "&quot;"
      case "'": result += "&#39;"
      default: result.append(character)
      }
    }
    return result
  }
}

/// Markup that is safe to place in a page. Outside this module it can only be built from text,
/// which is escaped, so doc content can't reach a page as raw markup by any public route.
public struct HTMLFragment: Sendable, Equatable {
  let markup: String

  init(trustedMarkup: String) {
    self.markup = trustedMarkup
  }

  public static func text(_ text: String) -> HTMLFragment {
    HTMLFragment(trustedMarkup: HTMLEscape.escape(text))
  }

  static func element(
    _ name: String, attributes: KeyValuePairs<String, String> = [:], _ children: [HTMLFragment]
  ) -> HTMLFragment {
    var open = "<\(name)"
    for (key, value) in attributes {
      open += " \(key)=\"\(HTMLEscape.escape(value))\""
    }
    return HTMLFragment(
      trustedMarkup: open + ">" + children.map(\.markup).joined() + "</\(name)>")
  }

  static func element(
    _ name: String, attributes: KeyValuePairs<String, String> = [:], text: String
  ) -> HTMLFragment {
    element(name, attributes: attributes, [.text(text)])
  }

  static func joined(_ fragments: [HTMLFragment]) -> HTMLFragment {
    HTMLFragment(trustedMarkup: fragments.map(\.markup).joined())
  }
}

/// A runtime capability the published page needs the viewer to grant. The skill that publishes
/// the page passes ``ArtifactPageShell/capabilityDeclaration`` as the Artifact tool's
/// `capabilities`; the page itself can't declare them.
public enum ArtifactCapability: String, CaseIterable, Sendable, Comparable {
  case comments
  case db

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The page frame every `design-render` page shares: title, theme tokens for light and dark,
/// phone-width layout, the capability declaration, optional JSON page data and one inline script.
/// The Artifact viewer wraps the file in its own document skeleton, so the shell emits no
/// doctype, `html`, `head` or `body` tags and opens with `<title>`.
public struct ArtifactPageShell: Sendable, Equatable {
  public let title: String
  public let body: HTMLFragment
  public let capabilities: [ArtifactCapability]
  /// Reaches the page only as JSON inside a `type="application/json"` block, with every `<`
  /// written as `<` so a value can never close the block.
  public let pageData: [String: String]
  /// Page code written by this module, never doc content.
  let script: String?

  public init(
    title: String, body: HTMLFragment, capabilities: [ArtifactCapability],
    pageData: [String: String] = [:], script: String? = nil
  ) {
    self.title = title
    self.body = body
    self.capabilities = Array(Set(capabilities)).sorted()
    self.pageData = pageData
    self.script = script
  }

  /// The Artifact tool's `capabilities` value for this page, e.g. `{"comments":{},"db":{}}`.
  public var capabilityDeclaration: String {
    "{" + capabilities.map { "\"\($0.rawValue)\":{}" }.joined(separator: ",") + "}"
  }

  public var html: String {
    var parts = [
      "<title>\(HTMLEscape.escape(title))</title>",
      "<meta name=\"artifact-capabilities\" content=\""
        + HTMLEscape.escape(capabilities.map(\.rawValue).joined(separator: " ")) + "\">",
      Self.fontLink,
      "<style>\n\(Self.stylesheet)</style>",
      "<main class=\"page\">\n\(body.markup)\n</main>",
    ]
    if !pageData.isEmpty {
      parts.append(
        "<script type=\"application/json\" id=\"page-data\">\(Self.scriptSafeJSON(pageData))</script>"
      )
    }
    if let script {
      parts.append("<script>\n\(script)\n</script>")
    }
    return parts.joined(separator: "\n") + "\n"
  }

  static func scriptSafeJSON(_ data: [String: String]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let encoded = (try? encoder.encode(data)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    // Inside JSON, `<`, `>`, `&` and the two line separators only occur in strings, where the
    // `\u` form means the same value; replacing them keeps `</script>` and `<!--` out of the block.
    return
      encoded
      .replacingOccurrences(of: "<", with: "\\u003c")
      .replacingOccurrences(of: ">", with: "\\u003e")
      .replacingOccurrences(of: "&", with: "\\u0026")
      .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
      .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
  }

  static let fontLink =
    "<link rel=\"stylesheet\" href=\"https://fonts.googleapis.com/css2?"
    + "family=IBM+Plex+Mono:wght@400;500&family=IBM+Plex+Sans:wght@400;500;600&display=swap\">"

  static let stylesheet = """
    :root {
      --paper: #f5f6f8;
      --surface: #ffffff;
      --ink: #1c2330;
      --muted: #5a6475;
      --rule: #d8dde5;
      --accent: #2c5a85;
      --accent-ink: #ffffff;
      --good: #25734a;
      --good-soft: #e3f2e9;
      --bad: #a93636;
      --bad-soft: #f8e4e4;
      --warn: #8a5a00;
      --warn-soft: #f7ecd6;
      --info: #2c5a85;
      --info-soft: #e2ebf4;
      --font-body: "IBM Plex Sans", -apple-system, "Segoe UI", system-ui, sans-serif;
      --font-mono: "IBM Plex Mono", ui-monospace, "SF Mono", Menlo, monospace;
    }
    @media (prefers-color-scheme: dark) {
      :root:not([data-theme="light"]) {
        color-scheme: dark;
        --paper: #11151c;
        --surface: #181e27;
        --ink: #e4e8ee;
        --muted: #9aa4b4;
        --rule: #2b3340;
        --accent: #7fb0de;
        --accent-ink: #0f1620;
        --good: #6fcf97;
        --good-soft: #17301f;
        --bad: #f08a8a;
        --bad-soft: #3a1c1c;
        --warn: #e5b45a;
        --warn-soft: #33280f;
        --info: #7fb0de;
        --info-soft: #172636;
      }
    }
    :root[data-theme="dark"] {
      color-scheme: dark;
      --paper: #11151c;
      --surface: #181e27;
      --ink: #e4e8ee;
      --muted: #9aa4b4;
      --rule: #2b3340;
      --accent: #7fb0de;
      --accent-ink: #0f1620;
      --good: #6fcf97;
      --good-soft: #17301f;
      --bad: #f08a8a;
      --bad-soft: #3a1c1c;
      --warn: #e5b45a;
      --warn-soft: #33280f;
      --info: #7fb0de;
      --info-soft: #172636;
    }
    body {
      background: var(--paper);
      color: var(--ink);
      font-family: var(--font-body);
      font-size: 15px;
      line-height: 1.55;
    }
    .page {
      max-width: 62rem;
      margin: 0 auto;
      padding-inline: 16px;
      padding-block: 24px 96px;
      display: grid;
      gap: 32px;
    }
    h1, h2, h3 { text-wrap: balance; line-height: 1.25; margin: 0; }
    h1 { font-size: 1.9rem; font-weight: 600; }
    h2 {
      font-size: 0.78rem; font-weight: 600; letter-spacing: 0.08em; text-transform: uppercase;
      color: var(--muted); margin-bottom: 12px;
    }
    p { margin: 0; max-width: 65ch; }
    section { display: grid; gap: 8px; }
    ul { margin: 0; padding-left: 1.2rem; display: grid; gap: 6px; }
    code { font-family: var(--font-mono); font-size: 0.9em; }
    .meta { display: flex; flex-wrap: wrap; gap: 8px; color: var(--muted); font-size: 0.85rem; }
    .chip {
      border: 1px solid var(--rule); border-radius: 999px; padding: 1px 10px;
      font-variant-numeric: tabular-nums;
    }
    .scroll { overflow-x: auto; }
    table { border-collapse: collapse; width: 100%; background: var(--surface); }
    th, td { text-align: left; vertical-align: top; padding: 10px 12px; border: 1px solid var(--rule); }
    th { font-weight: 600; font-size: 0.85rem; color: var(--muted); }
    figure {
      margin: 0; padding: 16px; background: var(--surface); border: 1px solid var(--rule);
      border-radius: 6px; overflow-x: auto;
    }
    pre.mermaid { margin: 0; font-family: var(--font-mono); font-size: 0.85rem; }
    .claims { list-style: none; padding: 0; }
    details { background: var(--surface); border: 1px solid var(--rule); border-radius: 6px; }
    summary { cursor: pointer; padding: 10px 12px; display: flex; gap: 10px; align-items: baseline; }
    summary:focus-visible, button:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
    .claim-body { padding: 0 12px 12px; display: grid; gap: 6px; }
    blockquote {
      margin: 0; padding: 8px 12px; border-left: 3px solid var(--rule);
      font-family: var(--font-mono); font-size: 0.85rem; overflow-x: auto; white-space: pre-wrap;
    }
    .cite { color: var(--muted); font-size: 0.8rem; font-family: var(--font-mono); overflow-wrap: anywhere; }
    .plain { padding: 10px 12px; display: flex; gap: 10px; align-items: baseline; }
    .badge {
      flex: none; font-size: 0.72rem; font-weight: 600; letter-spacing: 0.04em;
      text-transform: uppercase; border-radius: 4px; padding: 1px 7px;
      background: var(--info-soft); color: var(--info);
    }
    .badge[data-status="supported"] { background: var(--good-soft); color: var(--good); }
    .badge[data-status="refuted"], .badge[data-status="quote-fail"], .badge[data-status="no-claim"] {
      background: var(--bad-soft); color: var(--bad);
    }
    .badge[data-status="stale"], .badge[data-status="unverified"] {
      background: var(--warn-soft); color: var(--warn);
    }
    .approval {
      position: sticky; bottom: 0; background: var(--surface); border-top: 1px solid var(--rule);
      padding: 12px 16px calc(12px + env(safe-area-inset-bottom, 0px));
      display: flex; flex-wrap: wrap; gap: 12px; align-items: center; justify-content: flex-end;
    }
    .approval p { margin-right: auto; color: var(--muted); font-size: 0.9rem; }
    button {
      font: inherit; font-weight: 500; border-radius: 6px; padding: 8px 16px; cursor: pointer;
      border: 1px solid var(--rule); background: var(--surface); color: var(--ink);
    }
    button.primary { background: var(--accent); color: var(--accent-ink); border-color: var(--accent); }
    button:disabled { opacity: 0.5; cursor: default; }
    @media (prefers-reduced-motion: reduce) { * { transition: none !important; } }

    """
}
