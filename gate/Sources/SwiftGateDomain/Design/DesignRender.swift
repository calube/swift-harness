import Foundation

/// The design page a reviewer approves from: diagrams from the doc's Mermaid blocks, options as a
/// comparison table, evidence as status badges that expand to the cited quote, requirements and
/// tests by their statement, and prose only for the problem, risks and open questions.
///
/// Every string taken from the doc or a claim goes through ``HTMLEscape`` via ``HTMLFragment``.
/// Ids (`req-`, `test-`, `ev-`) appear only in `data-` attributes, never as reader-facing words.
public enum DesignRender {
  public struct Input: Sendable, Equatable {
    public let rawText: String
    public let claims: [Claim]
    /// `evidence check` results for `claims`. A claim with a result shows the status the check
    /// moves it to; one without shows its recorded status.
    public let checkResults: [EvidenceCheckResult]

    public init(rawText: String, claims: [Claim], checkResults: [EvidenceCheckResult]) {
      self.rawText = rawText
      self.claims = claims
      self.checkResults = checkResults
    }
  }

  public enum Badge: Sendable, Equatable {
    case claim(Claim.Status)
    case unverified
    /// A tag citing an id with no record in `claims.jsonl`.
    case missingClaim

    /// The `data-status` value the stylesheet keys on.
    public var status: String {
      switch self {
      case .claim(let status): status.rawValue
      case .unverified: "unverified"
      case .missingClaim: "no-claim"
      }
    }

    public var label: String {
      switch self {
      case .claim(let status):
        switch status {
        case .new: "Unchecked"
        case .quoteOk: "Quote found"
        case .quoteFail: "Quote missing"
        case .supported: "Supported"
        case .refuted: "Refuted"
        case .stale: "Stale"
        }
      case .unverified: "Unverified"
      case .missingClaim: "No claim record"
      }
    }
  }

  /// What the publishing skill declares: `comments` for review threads, `db` for the approval.
  public static let capabilities: [ArtifactCapability] = [.comments, .db]

  public static func page(_ input: Input) -> ArtifactPageShell {
    let document = DesignDocument(markdown: MarkdownDocument.parse(input.rawText))
    let designSha = DesignSha.of(input.rawText)
    let claims = effectiveClaims(input)
    let title =
      document.markdown.sections.first(where: { $0.level == 1 })?.heading ?? "Untitled design"
    let context = Context(document: document, rawText: input.rawText, claims: claims)

    var body: [HTMLFragment] = [header(title: title, document: document, designSha: designSha)]
    body.append(context.problem())
    body.append(context.requirements())
    body.append(context.architecture())
    body.append(context.options())
    body.append(context.taggedSection("Decision", section: document.decision))
    body.append(context.evidence())
    body.append(context.moduleKinds())
    body.append(context.testPlan())
    body.append(context.taggedSection("Perf & scale", section: document.perfAndScale))
    body.append(context.bulletSection("Risks", section: document.risks))
    body.append(context.bulletSection("Open questions", section: document.openQuestions))
    body.append(approvalBar(designSha: designSha))

    let fenceSections = [document.architecture] + document.options.map { Optional($0) }
    let hasDiagrams = fenceSections.contains { section in
      section?.fences.contains { $0.language == "mermaid" } ?? false
    }
    return ArtifactPageShell(
      title: title, body: .joined(body), capabilities: capabilities,
      libraries: hasDiagrams ? [.mermaid] : [], script: approvalScript)
  }

  // MARK: - Claims

  struct ShownClaim {
    let claim: Claim
    let status: Claim.Status
  }

  static func effectiveClaims(_ input: Input) -> [String: ShownClaim] {
    let results = Dictionary(
      input.checkResults.map { ($0.claimID, $0) }, uniquingKeysWith: { _, last in last })
    var shown: [String: ShownClaim] = [:]
    for claim in input.claims {
      let status = results[claim.id]?.claimStatus ?? claim.status
      shown[claim.id] = ShownClaim(claim: claim, status: status)
    }
    return shown
  }

  // MARK: - Header and approval

  static func header(title: String, document: DesignDocument, designSha: String) -> HTMLFragment {
    var chips: [HTMLFragment] = []
    if let status = document.status {
      chips.append(.element("span", attributes: ["class": "chip"], text: statusText(status)))
    }
    if let area = document.area {
      chips.append(.element("span", attributes: ["class": "chip"], text: "Area: \(area)"))
    }
    if let tier = document.tier {
      chips.append(.element("span", attributes: ["class": "chip"], text: "Review depth: \(tier)"))
    }
    chips.append(
      .element(
        "span", attributes: ["class": "chip", "title": designSha],
        text: "Revision \(designSha.prefix(10))"))
    return .element(
      "header", attributes: ["class": "masthead"],
      [.element("h1", text: title), .element("div", attributes: ["class": "meta"], chips)])
  }

  static func statusText(_ status: DesignDocument.Status) -> String {
    switch status {
    case .proposed: "Proposed"
    case .approved: "Approved"
    case .built: "Built"
    case .supersededBy(let slug): "Superseded by \(slug)"
    case .unknown(let raw): "Status: \(raw)"
    }
  }

  static func approvalBar(designSha: String) -> HTMLFragment {
    .element(
      "footer", attributes: ["class": "approval"],
      [
        .element(
          "p", attributes: ["id": "approval-status", "role": "status"],
          text: "Loading the current decision…"),
        .element(
          "button",
          attributes: [
            "type": "button", "data-decision": "request-changes", "data-design-sha": designSha,
            "disabled": "disabled",
          ], text: "Request changes"),
        .element(
          "button",
          attributes: [
            "type": "button", "class": "primary", "data-decision": "approve",
            "data-design-sha": designSha, "disabled": "disabled",
          ], text: "Approve"),
      ])
  }

  /// Writes `{decision, at}` to the page's `db`: collection `approval`, document id = the
  /// revision's designSha, which the design skill reads back with `ArtifactData`.
  static let approvalScript = """
    (function () {
      var status = document.getElementById("approval-status");
      var buttons = Array.prototype.slice.call(document.querySelectorAll("button[data-decision]"));
      var labels = { "approve": "Approved", "request-changes": "Changes requested" };
      function show(text) { status.textContent = text; }
      function enable(on) { buttons.forEach(function (b) { b.disabled = !on; }); }
      var pending = window.claude && typeof window.claude.use === "function"
        ? window.claude.use("db") : Promise.resolve(null);
      pending.then(function (db) {
        if (!db) {
          show("Approval isn't available in this view. Answer in the Claude session that shared this page.");
          return;
        }
        var sha = buttons[0].dataset.designSha;
        db.collection("approval").doc(sha).get().then(function (snap) {
          var data = snap.exists ? snap.data() : null;
          show(data && labels[data.decision]
            ? labels[data.decision] + " for this revision. You can change your decision."
            : "No decision yet for this revision.");
        }, function () { show("Couldn't read the current decision. You can still decide."); });
        enable(true);
        buttons.forEach(function (button) {
          button.addEventListener("click", function () {
            var decision = button.dataset.decision;
            var sha = button.dataset.designSha;
            enable(false);
            show("Saving…");
            db.collection("approval").doc(sha)
              .set({ decision: decision, at: (new Date).toISOString() })
              .then(function () {
                show(labels[decision] + ". Tell Claude in your session to continue.");
              }, function (error) {
                show(error && error.code === "invalid_argument"
                  ? "You can read this design but not decide on it. Ask its owner for Contributor access."
                  : "Couldn't save your decision. Try again.");
              })
              .then(function () { enable(true); });
          });
        });
      }, function () {
        show("Approval isn't available in this view. Answer in the Claude session that shared this page.");
      });
    })();
    """
}

// MARK: - Sections

extension DesignRender {
  struct Context {
    let document: DesignDocument
    let rawText: String
    let claims: [String: ShownClaim]

    func problem() -> HTMLFragment {
      section(
        "Problem", paragraphs(anchor: DesignDocument.RequiredSection.problem.anchor))
    }

    func requirements() -> HTMLFragment {
      let items = document.requirements.map { requirement in
        HTMLFragment.element(
          "li", attributes: ["data-requirement": requirement.id], [inline(requirement.statement)])
      }
      return section("Requirements", [.element("ul", items)])
    }

    func architecture() -> HTMLFragment {
      section("Architecture", diagrams(in: document.architecture))
    }

    func options() -> HTMLFragment {
      let rows = document.options.map { option in
        let name = optionName(option.heading)
        var cell = paragraphs(anchor: option.anchor, excludingSubsections: true)
        if !option.bullets.isEmpty {
          cell.append(.element("ul", option.bullets.map { .element("li", [inline($0.text)]) }))
        }
        cell += diagrams(in: option)
        return HTMLFragment.element(
          "tr", attributes: ["data-option": name],
          [.element("th", attributes: ["scope": "row"], text: name), .element("td", cell)])
      }
      let table = HTMLFragment.element(
        "table", attributes: ["class": "options"],
        [
          .element(
            "thead",
            [.element("tr", [.element("th", text: "Option"), .element("th", text: "Trade-offs")])]),
          .element("tbody", rows),
        ])
      return section("Options", [.element("div", attributes: ["class": "scroll"], [table])])
    }

    func evidence() -> HTMLFragment {
      let bullets =
        document.markdown.section(
          anchor: DesignDocument.RequiredSection.evidence.anchor)?.bullets ?? []
      return section("Evidence", [claimList(bullets)])
    }

    func taggedSection(_ heading: String, section source: MarkdownDocument.Section?)
      -> HTMLFragment
    {
      section(heading, [claimList(source?.bullets ?? [])])
    }

    func bulletSection(_ heading: String, section source: MarkdownDocument.Section?)
      -> HTMLFragment
    {
      let items = (source?.bullets ?? []).map { HTMLFragment.element("li", [inline($0.text)]) }
      return section(heading, [.element("ul", items)])
    }

    func moduleKinds() -> HTMLFragment {
      guard let table = document.moduleKinds else { return section("Module kinds", []) }
      let head = HTMLFragment.element(
        "thead", [.element("tr", table.header.map { .element("th", [inline($0)]) })])
      let rows = table.rows.map { row in
        HTMLFragment.element("tr", row.map { .element("td", [inline($0)]) })
      }
      return section(
        "Module kinds",
        [
          .element(
            "div", attributes: ["class": "scroll"],
            [.element("table", [head, .element("tbody", rows)])])
        ])
    }

    func testPlan() -> HTMLFragment {
      let items = document.testPlan.map { test in
        HTMLFragment.element(
          "li", attributes: ["data-test": test.id],
          [
            inline(test.behaviour.trimmingCharacters(in: .whitespaces)), .text(" "),
            .element(
              "span", attributes: ["class": "chip"],
              text: test.tier.isEmpty ? "No tier" : "Tier \(test.tier)"),
          ])
      }
      return section("Test plan", [.element("ul", items)])
    }

    // MARK: Building blocks

    func section(_ heading: String, _ content: [HTMLFragment]) -> HTMLFragment {
      .element("section", [.element("h2", text: heading)] + content)
    }

    func claimList(_ bullets: [MarkdownDocument.Bullet]) -> HTMLFragment {
      .element("ul", attributes: ["class": "claims"], bullets.map(claimItem))
    }

    /// One tagged bullet: its text with the tags removed, a badge per tag, and for each cited
    /// claim a disclosure holding the quote and where it comes from.
    func claimItem(_ bullet: MarkdownDocument.Bullet) -> HTMLFragment {
      let tags = bullet.tags.filter { $0 == "UNVERIFIED" || $0.hasPrefix("ev-") }
      let text = DesignRender.strippingTags(tags, from: bullet.text)
      var badges: [HTMLFragment] = []
      var cited: [ShownClaim] = []
      for tag in tags {
        let badge: Badge
        if tag == "UNVERIFIED" {
          badge = .unverified
        } else if let shown = claims[tag] {
          badge = .claim(shown.status)
          cited.append(shown)
        } else {
          badge = .missingClaim
        }
        badges.append(
          .element(
            "span", attributes: ["class": "badge", "data-status": badge.status], text: badge.label))
      }
      let claimIDs = tags.filter { $0 != "UNVERIFIED" }.joined(separator: " ")
      let summaryContent = badges + [.element("span", [inline(text)])]
      guard !cited.isEmpty else {
        return .element(
          "li", attributes: ["data-claim": claimIDs],
          [.element("div", attributes: ["class": "plain"], summaryContent)])
      }
      let bodies = cited.map { shown in
        var parts: [HTMLFragment] = [.element("p", text: shown.claim.text)]
        if let quote = shown.claim.citation.quote {
          parts.append(.element("blockquote", text: quote))
        }
        let pin = shown.claim.citation.pin.map { " · \($0)" } ?? ""
        parts.append(
          .element("p", attributes: ["class": "cite"], text: shown.claim.citation.loc + pin))
        return HTMLFragment.joined(parts)
      }
      return .element(
        "li", attributes: ["data-claim": claimIDs],
        [
          .element(
            "details",
            [
              .element("summary", summaryContent),
              .element("div", attributes: ["class": "claim-body"], bodies),
            ])
        ])
    }

    /// Mermaid source goes in as escaped text; the viewer renders `pre.mermaid` blocks itself.
    func diagrams(in source: MarkdownDocument.Section?) -> [HTMLFragment] {
      (source?.fences ?? []).filter { $0.language == "mermaid" }.map { fence in
        .element(
          "figure",
          [
            .element(
              "pre", attributes: ["class": "mermaid"], text: fence.body.joined(separator: "\n"))
          ])
      }
    }

    /// Running prose under `anchor`, one `<p>` per paragraph. Headings, bullets, tables and fences
    /// are left out: they're rendered from the parsed model instead.
    func paragraphs(anchor: String, excludingSubsections: Bool = false) -> [HTMLFragment] {
      let slice: ContextPackSlice
      do {
        slice = try MarkdownAnchorSlicer.slice(
          anchor: anchor, of: document.markdown, rawText: rawText, sourceLabel: "design")
      } catch {
        return [
          .element(
            "p", attributes: ["class": "cite"], text: "This section's text couldn't be located.")
        ]
      }
      var result: [HTMLFragment] = []
      var current: [String] = []
      var inFence: String?
      func flush() {
        if !current.isEmpty {
          result.append(.element("p", [inline(current.joined(separator: " "))]))
          current = []
        }
      }
      for (index, line) in slice.lines.enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let marker = inFence {
          if trimmed.hasPrefix(marker) { inFence = nil }
          continue
        }
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
          flush()
          inFence = String(trimmed.prefix(3))
          continue
        }
        if trimmed.hasPrefix("#") {
          flush()
          if index > 0, excludingSubsections { break }
          continue
        }
        if trimmed.isEmpty || trimmed.hasPrefix("|") || trimmed.hasPrefix("- ")
          || trimmed.hasPrefix("* ") || trimmed.hasPrefix("<!--")
        {
          flush()
          continue
        }
        current.append(trimmed)
      }
      flush()
      return result
    }

    func optionName(_ heading: String) -> String {
      guard let colon = heading.firstIndex(of: ":") else { return heading }
      let name = heading[heading.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      return name.isEmpty ? heading : name
    }
  }

  /// Backtick spans become `<code>`; everything is escaped. An unbalanced backtick leaves the
  /// whole string as plain text.
  static func inline(_ text: String) -> HTMLFragment {
    let pieces = text.split(separator: "`", omittingEmptySubsequences: false).map(String.init)
    guard pieces.count > 1, pieces.count % 2 == 1 else { return .text(text) }
    return .joined(
      pieces.enumerated().map { index, piece in
        index % 2 == 1 ? .element("code", text: piece) : .text(piece)
      })
  }

  static func strippingTags(_ tags: [String], from text: String) -> String {
    var result = text
    for tag in tags {
      result = result.replacingOccurrences(of: "[\(tag)]", with: "")
    }
    return result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
}
