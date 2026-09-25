import Foundation
import SwiftGateDomain
import Testing

@Suite("Design render — design page")
struct DesignRenderTests {
  static let fixturesRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures/design", directoryHint: .isDirectory)

  static let citedClaimID = "ev-tca-effect-run-supports-cancellation"

  static func validDoc() throws -> String {
    try String(contentsOf: fixturesRoot.appending(path: "valid.md"), encoding: .utf8)
  }

  static func claim(status: Claim.Status, quote: String = "public func cancellable") -> Claim {
    Claim(
      id: citedClaimID, lane: "packages", text: "Effect.run can be cancelled by id.",
      citation: Citation(
        kind: .file, loc: ".build/checkouts/tca/Cancellation.swift:L36-L36",
        pin: "swift-composable-architecture@1.26.2", quote: quote),
      status: status)
  }

  static func render(
    _ text: String, claims: [Claim] = [claim(status: .supported)],
    results: [EvidenceCheckResult] = []
  ) -> String {
    DesignRender.page(.init(rawText: text, claims: claims, checkResults: results)).html
  }

  /// What a reader sees: script and style bodies dropped, tags removed, entities decoded.
  static func visibleText(_ html: String) -> String {
    var text = html
    for element in ["script", "style"] {
      text = text.replacingOccurrences(
        of: "<\(element)[^>]*>[\\s\\S]*?</\(element)>", with: " ", options: .regularExpression)
    }
    text = text.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
    for (entity, character) in [
      ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&"),
    ] {
      text = text.replacingOccurrences(of: entity, with: character)
    }
    return text
  }

  static func occurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
  }

  // MARK: - Evidence badges

  @Test(
    "every claim status renders its own badge with a distinct label — catches a status falling into a generic badge"
  )
  func everyStatusHasBadge() throws {
    let text = try Self.validDoc()
    var labels: Set<String> = []
    for status in Claim.Status.allCases {
      let html = Self.render(text, claims: [Self.claim(status: status)])
      let badge = DesignRender.Badge.claim(status)
      #expect(
        html.contains("class=\"badge\" data-status=\"\(status.rawValue)\">\(badge.label)<"),
        "no \(status.rawValue) badge")
      labels.insert(badge.label)
    }
    #expect(labels.count == Claim.Status.allCases.count)
  }

  @Test(
    "an [UNVERIFIED] bullet gets the unverified badge and an unknown claim id its own badge — catches an untagged or dangling bullet reading as supported"
  )
  func unverifiedAndUnknownBadges() throws {
    let html = Self.render(try Self.validDoc(), claims: [])
    #expect(html.contains("data-status=\"unverified\">\(DesignRender.Badge.unverified.label)<"))
    #expect(html.contains("data-status=\"no-claim\">\(DesignRender.Badge.missingClaim.label)<"))
    #expect(!html.contains("class=\"badge\" data-status=\"supported\""))
  }

  @Test(
    "the evidence check outcome overrides the recorded status — catches a stale claim still shown as supported"
  )
  func checkResultOverridesRecordedStatus() throws {
    let stale = EvidenceCheckResult(
      claimID: Self.citedClaimID, kind: .file, outcome: .stale(.quoteGone))
    let html = Self.render(
      try Self.validDoc(), claims: [Self.claim(status: .supported)], results: [stale])
    #expect(html.contains("data-status=\"stale\""))
    #expect(!html.contains("class=\"badge\" data-status=\"supported\""))
  }

  @Test(
    "a badge expands to the cited quote — catches evidence shown without the words it rests on")
  func badgeExpandsToQuote() throws {
    let html = Self.render(
      try Self.validDoc(), claims: [Self.claim(status: .supported, quote: "cancelInFlight: Bool")])
    let details = try #require(html.range(of: "<details"))
    let quote = try #require(html.range(of: "cancelInFlight: Bool"))
    #expect(details.lowerBound < quote.lowerBound)
    #expect(html[quote.upperBound...].contains("</details>"))
  }

  // MARK: - Titles, not ids

  @Test(
    "requirements show their statement and keep ids only in data- attributes — catches ids as reader words"
  )
  func idsOnlyInDataAttributes() throws {
    let html = Self.render(try Self.validDoc())
    let visible = Self.visibleText(html)
    #expect(visible.contains("The client resubmits queued orders once connectivity returns."))
    #expect(html.contains("data-requirement=\"req-offline-queue-drains-on-reconnect\""))
    #expect(html.contains("data-test=\"test-queue-persists-across-relaunch\""))
    #expect(html.contains("data-claim=\"\(Self.citedClaimID)\""))
    let leaked = visible.range(
      of: "\\b(req|ev|test)-[a-z0-9]+(-[a-z0-9]+)+", options: .regularExpression)
    #expect(leaked == nil, "id in visible text: \(leaked.map { String(visible[$0]) } ?? "")")
  }

  @Test(
    "prose appears for problem, risks and open questions, and options become a comparison table — catches a transcription of every section"
  )
  func visualFirstSections() throws {
    let html = Self.render(try Self.validDoc())
    let visible = Self.visibleText(html)
    #expect(visible.contains("Guests on flaky Wi-Fi lose their cart"))
    #expect(visible.contains("Does silent background submission need explicit guest consent?"))
    #expect(visible.contains("needs a longer soak test before launch"))
    #expect(html.contains("<table class=\"options\">"))
    #expect(html.contains("data-option=\"Client-side queue with a TCA reducer\""))
    #expect(html.contains("data-option=\"Server-side draft orders\""))
    #expect(!visible.contains("2026-09-25: drafted"))
    #expect(Self.occurrences(of: "<pre class=\"mermaid\">", in: html) == 2)
  }

  // MARK: - Diagrams

  @Test(
    "a page with Mermaid fences loads exactly the pinned Mermaid script and starts it strict — catches diagrams shown as raw source"
  )
  func mermaidLibraryLoaded() throws {
    let html = Self.render(try Self.validDoc())
    let sources = html.components(separatedBy: "<script src=\"").dropFirst().map {
      String($0.prefix { $0 != "\"" })
    }
    #expect(sources == ["https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.min.js"])
    #expect(html.contains("securityLevel: \"strict\""))
    #expect(html.contains("startOnLoad: false"))
    #expect(html.contains("mermaid.run({ querySelector: \"pre.mermaid\" })"))
  }

  @Test("a design with no Mermaid fences loads no library — catches a script fetched for nothing")
  func noMermaidNoLibrary() throws {
    let text = try Self.validDoc().replacingOccurrences(of: "```mermaid", with: "```text")
    let html = Self.render(text)
    #expect(!html.contains("<script src="))
    #expect(!html.contains("mermaid.initialize"))
  }

  @Test(
    "an injected </script> in a Mermaid fence stays escaped text — catches diagram source breaking out of the page"
  )
  func mermaidFenceCannotBreakOut() throws {
    let clean = Self.render(try Self.validDoc())
    let text = try Self.validDoc().replacingOccurrences(
      of: "  B --> C[Checkout API]", with: "  B --> C[</script><script>alert(1)</script>]")
    let html = Self.render(text)
    #expect(html.contains("C[&lt;/script&gt;&lt;script&gt;alert(1)&lt;/script&gt;]"))
    #expect(!html.contains("alert(1)</script>"))
    #expect(
      Self.occurrences(of: "<script", in: html) == Self.occurrences(of: "<script", in: clean))
  }

  // MARK: - Approval buttons

  @Test("both approval buttons carry the doc's designSha — catches approving a different revision")
  func buttonsCarryDesignSha() throws {
    let text = try Self.validDoc()
    let sha = DesignSha.of(text)
    let html = Self.render(text)
    #expect(Self.occurrences(of: "data-design-sha=\"\(sha)\"", in: html) == 2)
    #expect(html.contains("data-decision=\"approve\""))
    #expect(html.contains("data-decision=\"request-changes\""))
    #expect(Self.occurrences(of: "data-design-sha=", in: html) == 2)
  }

  @Test(
    "the approval script writes collection approval, doc id designSha, {decision, at} — catches a write the skill can't read back"
  )
  func approvalScriptWritesDbShape() throws {
    let html = Self.render(try Self.validDoc())
    #expect(html.contains("window.claude.use(\"db\")"))
    #expect(html.contains("db.collection(\"approval\").doc(sha)"))
    #expect(html.contains(".set({ decision: decision, at: (new Date).toISOString() })"))
    #expect(DesignRender.capabilities == [.comments, .db])
  }

  // MARK: - Escaping

  @Test(
    "an injected </script> in a claim quote stays text — catches script injection through evidence")
  func quoteCannotBreakOut() throws {
    let payload = "</script><script>alert(1)</script>"
    let clean = Self.render(try Self.validDoc())
    let html = Self.render(
      try Self.validDoc(), claims: [Self.claim(status: .supported, quote: payload)])
    #expect(html.contains("&lt;/script&gt;&lt;script&gt;alert(1)&lt;/script&gt;"))
    #expect(!html.contains("alert(1)</script>"))
    #expect(
      Self.occurrences(of: "<script", in: html) == Self.occurrences(of: "<script", in: clean))
  }

  @Test(
    "doc text is escaped in text and attribute contexts — catches markup, a closing textarea or a javascript: link reaching the page"
  )
  func docTextEscaped() throws {
    var text = try Self.validDoc()
    text = text.replacingOccurrences(
      of: "Guests on flaky Wi-Fi",
      with: "Guests <img src=x onerror=alert(1)> see [docs](javascript:alert(1)) on flaky Wi-Fi")
    text = text.replacingOccurrences(
      of: "### Option 2: Server-side draft orders",
      with: "### Option 2: Server \"draft\" orders")
    text = text.replacingOccurrences(
      of: "- Does silent background", with: "- </textarea><b>bold</b> Does silent background")
    text = text.replacingOccurrences(
      of: "  B --> C[Checkout API]", with: "  B --> C[\"<b>Checkout</b> API\"]")
    let html = Self.render(text)
    #expect(html.contains("Guests &lt;img src=x onerror=alert(1)&gt;"))
    #expect(!html.contains("<img"))
    #expect(!html.contains("href=\"javascript:"))
    #expect(html.contains("[docs](javascript:alert(1))"))
    #expect(html.contains("data-option=\"Server &quot;draft&quot; orders\""))
    #expect(html.contains("&lt;/textarea&gt;&lt;b&gt;bold&lt;/b&gt;"))
    #expect(!html.contains("</textarea>"))
    #expect(html.contains("C[&quot;&lt;b&gt;Checkout&lt;/b&gt; API&quot;]"))
    #expect(!html.contains("<b>"))
  }

  @Test("the one escaping function covers & < > \" and ' — catches a context left unescaped")
  func escapeFunction() {
    #expect(HTMLEscape.escape("a&b<c>d\"e'f") == "a&amp;b&lt;c&gt;d&quot;e&#39;f")
    #expect(HTMLEscape.escape("</textarea>") == "&lt;/textarea&gt;")
  }

  // MARK: - Page shell

  @Test(
    "page data reaches a script only as JSON with </ escaped — catches a data value closing the script block"
  )
  func pageDataCannotCloseScript() throws {
    let payload = "</script><script>alert(1)</script>"
    let shell = ArtifactPageShell(
      title: "T", body: .text("b"), capabilities: [.db], pageData: ["quote": payload],
      script: "void 0;")
    let html = shell.html
    let start = try #require(html.range(of: "id=\"page-data\">"))
    let end = try #require(html[start.upperBound...].range(of: "</script>"))
    let json = Data(html[start.upperBound..<end.lowerBound].utf8)
    #expect(try JSONDecoder().decode([String: String].self, from: json) == ["quote": payload])
    #expect(!html.contains("alert(1)</script>"))
    #expect(Self.occurrences(of: "<script", in: html) == 2)
    #expect(Self.occurrences(of: "</script>", in: html) == 2)
  }

  @Test(
    "the shell meets the artifact page contract — catches a page the viewer can't title, theme or fit to a phone"
  )
  func shellContract() {
    let html = ArtifactPageShell(
      title: "Offline <order> queue", body: .text("x"), capabilities: [.comments, .db]
    ).html
    #expect(html.hasPrefix("<title>Offline &lt;order&gt; queue</title>"))
    for forbidden in ["<!doctype", "<!DOCTYPE", "<html", "<head", "<body"] {
      #expect(!html.contains(forbidden), "shell emits \(forbidden)")
    }
    #expect(html.contains("@media (prefers-color-scheme: dark)"))
    #expect(html.contains(":root:not([data-theme=\"light\"])"))
    #expect(html.contains(":root[data-theme=\"dark\"]"))
    #expect(html.contains("background: var(--paper)"))
    #expect(html.contains("overflow-x: auto"))
    #expect(html.contains("<meta name=\"artifact-capabilities\" content=\"comments db\">"))
    let scriptSources = html.components(separatedBy: "<script src=").dropFirst()
    #expect(scriptSources.isEmpty)
    #expect(
      ArtifactPageShell(title: "t", body: .text(""), capabilities: [.db, .comments])
        .capabilityDeclaration == "{\"comments\":{},\"db\":{}}")
  }
}
