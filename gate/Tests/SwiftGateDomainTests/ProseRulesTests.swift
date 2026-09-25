import SwiftGateDomain
import Testing

@Suite("Prose rules")
struct ProseRulesTests {
  static func check(_ text: String, ceiling: Int = 40) throws -> [Finding] {
    try ProseRules.check(text, file: "docs/topic.md", sentenceCeiling: ceiling)
  }

  static func hits(_ rule: ProseRule, in text: String, ceiling: Int = 40) throws -> [Finding] {
    try check(text, ceiling: ceiling).filter { $0.ruleID == rule.id }
  }

  // MARK: - Rule ids

  @Test(
    "rule ids are the closed prose set and every finding gates — catches a renamed id breaking waivers and skills"
  )
  func ruleIds() throws {
    #expect(
      ProseRule.allCases.map(\.id) == [
        "prose.adverb", "prose.em-dash", "prose.number-word", "prose.passive-voice",
        "prose.filler", "prose.jargon", "prose.sentence-length",
      ])
    let findings = try Self.check("We leverage caches — it quickly runs three checks.")
    #expect(!findings.isEmpty)
    #expect(findings.allSatisfy { $0.severity == .major && $0.file == "docs/topic.md" })
  }

  // MARK: - Adverbs

  @Test("an -ly adverb is flagged with its line and word — catches adverbs passing the gate")
  func adverbFlagged() throws {
    let findings = try Self.hits(.adverb, in: "Intro.\n\nThe gate quickly rejects the file.\n")
    #expect(findings.map(\.line) == [3])
    #expect(findings.first?.message.contains("\"quickly\"") == true)
  }

  @Test(
    "early, only, family, apply and other -ly non-adverbs pass — catches a suffix match flagging nouns and verbs"
  )
  func adverbFalsePositives() throws {
    let text = """
      Run it early. Only the family of rules can apply or reply. The daily build is likely to
      supply a friendly, user-friendly and read-only view. Rely on the assembly. Fly to Italy
      with Emily.
      """
    #expect(try Self.hits(.adverb, in: text).map(\.message) == [])
  }

  // MARK: - Em-dashes

  @Test("an em-dash in prose is flagged — catches em-dashes passing the gate")
  func emDashFlagged() throws {
    let findings = try Self.hits(.emDash, in: "The gate runs — then it stops.\n")
    #expect(findings.map(\.line) == [1])
    #expect(findings.first?.message.contains("runs — then") == true)
  }

  @Test(
    "hyphen ranges, en-dash ranges and em-dashes inside code pass — catches ranges and code flagged as em-dashes"
  )
  func emDashFalsePositives() throws {
    let text = """
      Use 4-5 files and 40–400 lines, as in `a — b`.

      ```swift
      let x = "a — b"
      ```
      """
    #expect(try Self.hits(.emDash, in: text).map(\.message) == [])
  }

  // MARK: - Number words

  @Test("a number word where a numeral fits is flagged — catches spelled-out counts passing")
  func numberWordFlagged() throws {
    let findings = try Self.hits(
      .numberWord, in: "The gate runs three checks and one file.\nTwenty agents run.\n")
    #expect(findings.map(\.line) == [1, 1, 2])
    #expect(findings.first?.message.contains("\"three\"") == true)
  }

  @Test(
    "one of, zero-cost, no one, one-off, ordinals and number words in names pass — catches pronouns and names flagged as counts"
  )
  func numberWordFalsePositives() throws {
    let text = """
      Pick one of the files. A zero-cost check. No one reads the one-off log. The first and
      second waves use the Seven Seas library and the Phase Two branch. Each one works. Pick two.
      One could use a one-to-one mapping.
      """
    #expect(try Self.hits(.numberWord, in: text).map(\.message) == [])
  }

  // MARK: - Passive voice

  @Test(
    "is based and is used to are flagged as passive — catches passive constructions passing"
  )
  func passiveFlagged() throws {
    let findings = try Self.hits(
      .passiveVoice,
      in: "The config is based on TOML.\nThe flag is used to skip.\nIt was written by hand.\n")
    #expect(findings.map(\.line) == [1, 2, 3])
    #expect(findings.first?.message.contains("\"is based\"") == true)
  }

  @Test(
    "state adjectives after a be-verb pass — catches is ready or is closed flagged as passive"
  )
  func passiveFalsePositives() throws {
    let text = """
      The plan is ready. The lock is closed. The value is unchanged and the flag is read-only.
      The seed is here. The task is done.
      """
    #expect(try Self.hits(.passiveVoice, in: text).map(\.message) == [])
  }

  // MARK: - Filler and jargon

  @Test("a filler phrase is flagged once, by its longest match — catches filler passing")
  func fillerFlagged() throws {
    let findings = try Self.hits(
      .filler, in: "Run it in order to check.\nIt fails due to the fact that it is very slow.\n")
    #expect(findings.map(\.line) == [1, 2, 2])
    #expect(findings.map(\.message).contains { $0.contains("\"due to the fact that\"") })
    #expect(!findings.map(\.message).contains { $0.contains("\"the fact that\"") })
  }

  @Test("filler words are not also reported as adverbs — catches double-counting one word")
  func fillerNotDoubleCounted() throws {
    let findings = try Self.check("It basically works.")
    #expect(findings.map(\.ruleID) == [ProseRule.filler.id])
  }

  @Test("a business-jargon phrase is flagged — catches jargon passing")
  func jargonFlagged() throws {
    let findings = try Self.hits(
      .jargon,
      in: "We leverage the cache.\nThis is a best-in-class, low-hanging fruit.\nKey takeaways.\n")
    #expect(findings.map(\.line) == [1, 2, 2, 3])
    #expect(findings.last?.message.contains("\"Key takeaways\"") == true)
  }

  @Test(
    "jargon inside backticks, code fences and link targets never counts — catches technical terms flagged as jargon"
  )
  func jargonFalsePositives() throws {
    let text = """
      The `leverage` flag, [cache](docs/synergy.md) and https://example.com/seamless help.

      ```text
      leverage synergy
      ```
      """
    #expect(try Self.hits(.jargon, in: text).map(\.message) == [])
  }

  // MARK: - Sentence length

  @Test(
    "a sentence over the ceiling is flagged at its first line — catches long sentences passing"
  )
  func sentenceOverCeiling() throws {
    let words = (1...12).map { "word\($0)" }
    let text =
      "Short.\n\n" + words[0..<6].joined(separator: " ") + "\n"
      + words[6...].joined(separator: " ") + ". Next.\n"
    let findings = try Self.hits(.sentenceLength, in: text, ceiling: 11)
    #expect(findings.map(\.line) == [3])
    #expect(findings.first?.message.contains("12 words") == true)
    #expect(try Self.hits(.sentenceLength, in: text, ceiling: 12).map(\.message) == [])
  }

  @Test(
    "abbreviations like e.g. and version numbers don't end a sentence — catches a split hiding a long sentence"
  )
  func sentenceSplitAbbreviations() throws {
    let text = "Use a tool, e.g. the gate, or version 1.2 of it now."
    #expect(try Self.hits(.sentenceLength, in: text, ceiling: 11).count == 1)
    #expect(try Self.hits(.sentenceLength, in: text, ceiling: 12).map(\.message) == [])
  }

  @Test("each bullet is its own sentence — catches a list read as one long sentence")
  func bulletsAreSeparate() throws {
    let text = "- one two three four\n- five six seven eight\n"
    #expect(try Self.hits(.sentenceLength, in: text, ceiling: 4).map(\.message) == [])
  }

  // MARK: - What is not prose

  @Test(
    "code fences, mermaid, tables, HTML comments, inline code and frontmatter are ignored — catches false positives on code"
  )
  func nonProseIgnored() throws {
    let text = """
      ---
      title: quickly — three things are used
      ---
      # Heading

      ```swift
      let a = b — quickly  // three are used
      ```

      ~~~mermaid
      flowchart LR
        A -- quickly --> B
      ~~~

      | Rule | Note |
      |---|---|
      | adverb | quickly — three are used |

      <!-- quickly — three are used
      we leverage it -->

      Run `x — quickly is used` here.
      """
    #expect(try Self.check(text).map(\.message) == [])
  }

  @Test(
    "a finding after frontmatter and a fence keeps its real file line — catches line numbers counted from the body"
  )
  func lineNumbersAfterSkippedBlocks() throws {
    let text = """
      ---
      status: draft
      ---
      ```
      code
      ```
      It runs quickly.
      """
    #expect(try Self.hits(.adverb, in: text).map(\.line) == [7])
  }

  @Test("headings and blockquotes are prose — catches a heading escaping the rules")
  func headingsChecked() throws {
    let findings = try Self.hits(.adverb, in: "## Quickly running\n\n> It really works.\n")
    #expect(findings.map(\.line) == [1])
    #expect(try Self.hits(.filler, in: "> It really works.\n").map(\.line) == [1])
    let headed = "# Setup steps\nRun it now.\n"
    #expect(try Self.hits(.sentenceLength, in: headed, ceiling: 3).map(\.message) == [])
  }
}
