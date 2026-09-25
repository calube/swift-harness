/// The closed set of `swiftgate prose` rules (spec §6.2). A finding's rule id is `prose.<raw>`.
public enum ProseRule: String, Sendable, CaseIterable {
  case adverb
  case emDash = "em-dash"
  case numberWord = "number-word"
  case passiveVoice = "passive-voice"
  case filler
  case jargon
  case sentenceLength = "sentence-length"

  public var id: String { "prose.\(rawValue)" }
}

/// Mechanical plain-English checks over a markdown file's running prose. Only what
/// ``MarkdownDocument/proseLines(_:)`` yields is read, so code, diagrams, tables, HTML comments
/// and frontmatter never produce a finding. Every finding is `major`: spec §7.3 makes
/// `swiftgate prose` the gate the drafter's prose pass must clear.
///
/// The word lists are heuristics, not a parser. Passive voice is a be-verb, optionally one
/// modifier, then a participle: an irregular one from ``ProseLexicon/irregularParticiples`` or a
/// word ending in `-ed`. That misses passives with an unlisted irregular participle or a `get`
/// auxiliary, and it can't tell a stative adjective from a passive, so common state adjectives
/// (`closed`, `limited`, `deprecated`) and `un-…-ed` words (`unchanged`) are exempt by list.
public enum ProseRules {
  public static let severity: Severity = .major

  public static func check(_ text: String, file: String, sentenceCeiling: Int)
    throws(ReportContractViolation) -> [Finding]
  {
    var findings: [Finding] = []
    for block in ProseBlock.blocks(MarkdownDocument.proseLines(text)) {
      for sentence in block.sentences() {
        for hit in hits(in: sentence, ceiling: sentenceCeiling) {
          findings.append(
            try Finding(
              ruleID: hit.rule.id, severity: severity, file: file,
              line: block.line(at: hit.offset), message: hit.message, failureScenario: nil))
        }
      }
    }
    return findings
  }

  struct Hit {
    let rule: ProseRule
    let offset: Int
    let message: String
  }

  static func hits(in sentence: ProseSentence, ceiling: Int) -> [Hit] {
    let words = sentence.words
    var consumed = Set<Int>()
    var result: [Hit] = []
    result += phraseHits(.jargon, ProseLexicon.jargon, words, sentence, &consumed) {
      "jargon \"\($0)\": say what it does in plain words"
    }
    result += phraseHits(.filler, ProseLexicon.filler, words, sentence, &consumed) {
      "filler \"\($0)\": cut it"
    }
    for (index, word) in words.enumerated() where !consumed.contains(index) {
      if isAdverb(word, sentenceInitial: index == 0) {
        result.append(
          Hit(
            rule: .adverb, offset: word.start,
            message: "adverb \"\(word.text)\": cut it or use a stronger verb"))
      }
      if isNumberWord(at: index, in: words, sentence: sentence) {
        result.append(
          Hit(
            rule: .numberWord, offset: word.start,
            message: "number word \"\(word.text)\": use the numeral"))
      }
      if let end = passiveEnd(at: index, in: words, sentence: sentence) {
        result.append(
          Hit(
            rule: .passiveVoice, offset: word.start,
            message:
              "passive voice \"\(sentence.text(word.start..<end))\": name who acts"))
      }
    }
    result += emDashHits(sentence)
    let count = sentence.wordCount
    if count > ceiling {
      result.append(
        Hit(
          rule: .sentenceLength, offset: sentence.range.lowerBound,
          message:
            "sentence of \(count) words is over the \(ceiling)-word ceiling: "
            + "\"\(sentence.opening(words: 8))…\""))
    }
    return result.sorted { $0.offset < $1.offset }
  }

  // MARK: - Word rules

  static func isAdverb(_ word: ProseWord, sentenceInitial: Bool) -> Bool {
    let lower = word.lower
    guard lower.hasSuffix("ly"), lower.count >= 4, !lower.contains("'") else { return false }
    if word.isCapitalized, !sentenceInitial { return false }
    return !ProseLexicon.lyNonAdverbs.contains(lower)
  }

  static func isNumberWord(at index: Int, in words: [ProseWord], sentence: ProseSentence) -> Bool {
    let word = words[index]
    guard ProseLexicon.numberWords.contains(word.lower) else { return false }
    guard !word.hyphenBefore, !word.hyphenAfter else { return false }
    if word.isCapitalized, index != 0 { return false }
    guard index + 1 < words.count, sentence.onlySpaceBetween(word, words[index + 1]) else {
      return false
    }
    let next = words[index + 1].lower
    if ProseLexicon.notCountedAfterNumber.contains(next) { return false }
    if word.lower == "one" {
      if ProseLexicon.pronounAfterOne.contains(next) { return false }
      if index > 0, ProseLexicon.pronounBeforeOne.contains(words[index - 1].lower) {
        return false
      }
    }
    return true
  }

  /// End offset of a passive construction starting at `index`, or `nil`.
  static func passiveEnd(at index: Int, in words: [ProseWord], sentence: ProseSentence) -> Int? {
    guard ProseLexicon.beVerbs.contains(words[index].lower) else { return nil }
    var next = index + 1
    guard next < words.count, sentence.onlySpaceBetween(words[index], words[next]) else {
      return nil
    }
    let modifier = words[next]
    if ProseLexicon.passiveModifiers.contains(modifier.lower)
      || isAdverb(modifier, sentenceInitial: false)
    {
      next += 1
      guard next < words.count, sentence.onlySpaceBetween(modifier, words[next]) else {
        return nil
      }
    }
    let candidate = words[next]
    guard !candidate.hyphenAfter, isParticiple(candidate.lower) else { return nil }
    return candidate.end
  }

  static func isParticiple(_ lower: String) -> Bool {
    if ProseLexicon.irregularParticiples.contains(lower) { return true }
    guard lower.hasSuffix("ed"), lower.count >= 4, !lower.hasSuffix("eed") else { return false }
    if lower.hasPrefix("un") { return false }
    return !ProseLexicon.statesEndingInEd.contains(lower)
  }

  static func phraseHits(
    _ rule: ProseRule, _ phrases: [[String]], _ words: [ProseWord], _ sentence: ProseSentence,
    _ consumed: inout Set<Int>, message: (String) -> String
  ) -> [Hit] {
    var result: [Hit] = []
    var index = 0
    while index < words.count {
      let match = phrases.first { phrase in
        let end = index + phrase.count
        guard end <= words.count else { return false }
        let span = index..<end
        guard !span.contains(where: consumed.contains) else { return false }
        guard !words[index].hyphenBefore, !words[end - 1].hyphenAfter else { return false }
        for (offset, part) in phrase.enumerated() {
          let word = words[index + offset]
          guard word.lower == part else { return false }
          if offset > 0, !sentence.onlySpaceOrHyphenBetween(words[index + offset - 1], word) {
            return false
          }
        }
        return true
      }
      if let match {
        let last = words[index + match.count - 1]
        result.append(
          Hit(
            rule: rule, offset: words[index].start,
            message: message(sentence.text(words[index].start..<last.end))))
        consumed.formUnion(index..<(index + match.count))
        index += match.count
      } else {
        index += 1
      }
    }
    return result
  }

  // MARK: - Character rules

  static func emDashHits(_ sentence: ProseSentence) -> [Hit] {
    let tokens = sentence.spaceSeparatedTokens
    return tokens.indices.compactMap { index in
      let token = tokens[index]
      let text = sentence.text(token)
      guard text.contains("\u{2014}") || text == "--" else { return nil }
      let from = tokens[max(0, index - 1)].lowerBound
      let to = tokens[min(tokens.count - 1, index + 1)].upperBound
      return Hit(
        rule: .emDash, offset: token.lowerBound,
        message:
          "em-dash in \"\(sentence.text(from..<to))\": use a comma, colon, parentheses or "
          + "two sentences")
    }
  }
}

// MARK: - Text model

/// One run of prose that a sentence may not cross: a paragraph, a list item or a heading. Its
/// lines are joined by one space, and `lineStarts` maps a character offset back to a file line.
struct ProseBlock {
  let characters: [Character]
  let lineStarts: [(offset: Int, line: Int)]

  static func blocks(_ lines: [MarkdownDocument.ProseLine]) -> [ProseBlock] {
    var result: [ProseBlock] = []
    var characters: [Character] = []
    var starts: [(offset: Int, line: Int)] = []
    for line in lines {
      if line.startsBlock, !starts.isEmpty {
        result.append(ProseBlock(characters: characters, lineStarts: starts))
        characters = []
        starts = []
      }
      if !starts.isEmpty { characters.append(" ") }
      starts.append((characters.count, line.number))
      characters.append(contentsOf: line.text)
    }
    if !starts.isEmpty { result.append(ProseBlock(characters: characters, lineStarts: starts)) }
    return result
  }

  func line(at offset: Int) -> Int {
    lineStarts.last { $0.offset <= offset }?.line ?? lineStarts[0].line
  }

  /// Splits at `.`, `!` or `?` followed by whitespace and then an uppercase letter, a digit or
  /// masked code, so `e.g. the` and `1.2` stay inside one sentence.
  func sentences() -> [ProseSentence] {
    var result: [ProseSentence] = []
    var start = 0
    var index = 0
    while index < characters.count {
      if ".!?".contains(characters[index]), endsSentence(after: index) {
        result.append(ProseSentence(characters: characters, range: start..<(index + 1)))
        start = index + 1
        while start < characters.count, characters[start].isWhitespace { start += 1 }
        index = start
        continue
      }
      index += 1
    }
    if start < characters.count {
      result.append(ProseSentence(characters: characters, range: start..<characters.count))
    }
    return result
  }

  private func endsSentence(after index: Int) -> Bool {
    let next = index + 1
    guard next < characters.count else { return true }
    guard characters[next].isWhitespace else { return false }
    guard let following = characters[next...].first(where: { !$0.isWhitespace }) else {
      return true
    }
    return following.isUppercase || following.isNumber
      || following == MarkdownDocument.maskedSpan
  }
}

struct ProseWord {
  let text: String
  let lower: String
  let start: Int
  let end: Int
  let hyphenBefore: Bool
  let hyphenAfter: Bool

  var isCapitalized: Bool { text.first?.isUppercase == true }
}

struct ProseSentence {
  let characters: [Character]
  let range: Range<Int>

  func text(_ span: Range<Int>) -> String { String(characters[span]) }

  /// Letter runs with inner apostrophes. A run touching a digit (`x86`, `3rd`) is not a word.
  var words: [ProseWord] {
    var result: [ProseWord] = []
    var index = range.lowerBound
    while index < range.upperBound {
      guard characters[index].isLetter || characters[index].isNumber else {
        index += 1
        continue
      }
      let start = index
      var hasDigit = false
      while index < range.upperBound {
        let character = characters[index]
        if character.isNumber { hasDigit = true }
        let innerApostrophe =
          (character == "'" || character == "\u{2019}") && index + 1 < range.upperBound
          && characters[index + 1].isLetter
        guard character.isLetter || character.isNumber || innerApostrophe else { break }
        index += 1
      }
      if hasDigit { continue }
      let text = String(characters[start..<index]).replacingOccurrences(of: "\u{2019}", with: "'")
      result.append(
        ProseWord(
          text: text, lower: text.lowercased(), start: start, end: index,
          hyphenBefore: start > range.lowerBound && characters[start - 1] == "-",
          hyphenAfter: index < range.upperBound && characters[index] == "-"))
    }
    return result
  }

  var spaceSeparatedTokens: [Range<Int>] {
    var result: [Range<Int>] = []
    var index = range.lowerBound
    while index < range.upperBound {
      if characters[index].isWhitespace {
        index += 1
        continue
      }
      let start = index
      while index < range.upperBound, !characters[index].isWhitespace { index += 1 }
      result.append(start..<index)
    }
    return result
  }

  var wordCount: Int {
    spaceSeparatedTokens.count { token in
      characters[token].contains {
        $0.isLetter || $0.isNumber || $0 == MarkdownDocument.maskedSpan
      }
    }
  }

  func opening(words count: Int) -> String {
    spaceSeparatedTokens.prefix(count).map(text).joined(separator: " ")
  }

  func onlySpaceBetween(_ first: ProseWord, _ second: ProseWord) -> Bool {
    characters[first.end..<second.start].allSatisfy(\.isWhitespace)
  }

  func onlySpaceOrHyphenBetween(_ first: ProseWord, _ second: ProseWord) -> Bool {
    characters[first.end..<second.start].allSatisfy { $0.isWhitespace || $0 == "-" }
  }
}

// MARK: - Word lists

/// The fixed lists behind the prose rules, written for this harness. Only the sentence ceiling is
/// configurable (`[docs] sentence_ceiling`); `[docs.banned_phrases]` stays with `docs-lint`.
enum ProseLexicon {
  static func phrases(_ list: [String]) -> [[String]] {
    list.map { $0.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init) }
  }

  static let jargon = phrases([
    "leverage", "leverages", "leveraged", "leveraging", "synergy", "synergies", "synergistic",
    "paradigm shift", "best-in-class", "world-class", "cutting-edge", "bleeding-edge",
    "game changer", "game-changing", "move the needle", "circle back", "low-hanging fruit",
    "deep dive", "touch base", "value-add", "value-added", "actionable", "holistic",
    "holistically", "seamless", "seamlessly", "empower", "empowers", "empowering", "streamline",
    "streamlines", "streamlined", "utilize", "utilizes", "utilized", "utilizing", "utilise",
    "utilization", "going forward", "north star", "thought leader", "thought leadership",
    "mission-critical", "win-win", "boil the ocean", "next-generation", "key takeaway",
    "key takeaways", "learnings", "ideate", "operationalize", "incentivize", "double-click",
    "drill down", "low-lift", "heavy lift", "unlock value",
  ])

  static let filler = phrases([
    "in order to", "it's worth noting", "it is worth noting", "it's worth mentioning",
    "it is worth mentioning", "needless to say", "at the end of the day",
    "for all intents and purposes", "due to the fact that", "the fact that",
    "at this point in time", "in terms of", "a number of", "it should be noted",
    "it goes without saying", "as a matter of fact", "in the event that", "please note",
    "each and every", "first and foremost", "in fact", "of course", "very", "really", "quite",
    "just", "basically", "actually", "simply", "literally", "essentially", "totally", "somewhat",
    "obviously",
  ])

  /// Words ending in `-ly` that are nouns, verbs or adjectives, not adverbs.
  static let lyNonAdverbs: Set<String> = [
    "early", "only", "family", "apply", "reply", "supply", "comply", "imply", "multiply", "ally",
    "rely", "likely", "unlikely", "friendly", "unfriendly", "lovely", "lonely", "costly",
    "deadly", "daily", "weekly", "monthly", "yearly", "hourly", "nightly", "quarterly",
    "biweekly", "orderly", "elderly", "timely", "untimely", "ugly", "silly", "holy", "curly",
    "chilly", "lively", "belly", "bully", "rally", "tally", "jelly", "lily", "holly", "folly",
    "jolly", "assembly", "anomaly", "monopoly", "butterfly", "readonly", "oily", "hilly",
    "woolly", "wily", "burly", "surly", "sully", "gully", "melancholy", "poly", "firefly",
    "dragonfly", "underbelly", "homily", "doily", "gnarly", "scholarly", "worldly", "ghostly",
    "heavenly", "manly", "bodily", "comely", "stately", "lowly",
  ]

  static let numberWords: Set<String> = [
    "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
    "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
    "nineteen", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
    "hundred", "thousand", "million", "billion",
  ]

  /// A number word followed by one of these is part of a phrase (`one of`, `two or three`), not
  /// a count a numeral would replace.
  static let notCountedAfterNumber: Set<String> = [
    "of", "or", "and", "to", "than", "per", "more", "less", "another",
  ]

  /// `one` as a pronoun: `the one that`, `one could`, `one by one`.
  static let pronounAfterOne: Set<String> = [
    "by", "is", "was", "are", "were", "could", "would", "can", "may", "might", "must", "should",
    "will", "that", "which", "who", "way", "day", "time", "at", "in", "on", "for", "has", "does",
    "with", "from", "here", "there",
  ]

  static let pronounBeforeOne: Set<String> = [
    "the", "no", "any", "each", "every", "this", "that", "which", "a", "an", "only", "someone",
  ]

  static let beVerbs: Set<String> = [
    "am", "is", "are", "was", "were", "be", "been", "being", "isn't", "aren't", "wasn't",
    "weren't",
  ]

  static let passiveModifiers: Set<String> = [
    "not", "never", "also", "always", "still", "already", "then", "now", "only", "just", "often",
    "sometimes", "even",
  ]

  static let irregularParticiples: Set<String> = [
    "built", "rebuilt", "written", "rewritten", "overwritten", "run", "rerun", "made", "given",
    "taken", "seen", "known", "shown", "held", "kept", "found", "sent", "set", "reset", "put",
    "read", "left", "lost", "paid", "told", "thrown", "chosen", "broken", "frozen", "hidden",
    "driven", "drawn", "grown", "understood", "bound", "fed", "led", "meant", "sold", "spent",
    "split", "struck", "torn", "worn", "won", "begun", "bought", "brought", "caught", "taught",
    "thought", "sought", "forbidden", "forgotten", "gotten", "withheld", "cut", "hit", "spun",
    "sworn", "stolen", "ridden", "eaten", "beaten", "bitten", "shaken", "woven", "overridden",
    "dealt", "dug", "hung", "laid", "lit", "shot", "sung", "sunk", "swept", "thrust", "upheld",
    "withdrawn",
  ]

  /// `-ed` words that read as a state after a be-verb (`the lock is closed`), not a passive.
  static let statesEndingInEd: Set<String> = [
    "closed", "finished", "tired", "interested", "excited", "concerned", "confused", "pleased",
    "bored", "dedicated", "detailed", "advanced", "complicated", "sophisticated", "experienced",
    "married", "limited", "related", "supposed", "outdated", "deprecated", "shed", "sled",
    "sped", "aged", "hundred", "sacred", "naked", "wicked", "rugged", "ragged", "beloved",
  ]
}
