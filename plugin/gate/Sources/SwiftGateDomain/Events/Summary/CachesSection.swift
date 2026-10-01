import Foundation

/// Hit rate and stale keys per cache.
public struct CachesSection: EventSummarySection {
  public init() {}

  public var id: EventSummarySectionID { .caches }

  /// A key keeps serving its old answer after its inputs change until something stores a new
  /// one, so only a replaced answer shows; the summary says so whatever the count.
  static let invisibleStaleNote =
    "a stale hit that no later store replaces stays invisible, so 0 stale keys doesn't mean no stale hits"
  /// The most stale keys listed by hash.
  static let listedStaleKeys = 10

  public func summarize(_ input: EventSummaryInput) -> EventSummarySectionReport? {
    var lookups: [CacheName: [(time: Date, lookup: CacheLookupEvent)]] = [:]
    for stored in input.events {
      guard case .cacheLookup(let lookup) = stored.event.payload else { continue }
      lookups[lookup.cache, default: []].append((stored.event.time, lookup))
    }
    guard !lookups.isEmpty else { return nil }

    var lines: [String] = []
    var metrics: [EventSummaryMetric] = []
    for cache in CacheName.allCases {
      guard let events = lookups[cache] else { continue }
      let ordered = events.enumerated().sorted {
        ($0.element.time, $0.offset) < ($1.element.time, $1.offset)
      }.map(\.element.lookup)
      report(cache, ordered, lines: &lines, metrics: &metrics)
    }
    lines.append(Self.invisibleStaleNote)
    return EventSummarySectionReport(id: id, state: .reported, lines: lines, metrics: metrics)
  }

  private func report(
    _ cache: CacheName, _ lookups: [CacheLookupEvent], lines: inout [String],
    metrics: inout [EventSummaryMetric]
  ) {
    func count(_ outcome: CacheLookupOutcome) -> Int { lookups.count { $0.outcome == outcome } }
    let hits = count(.hit)
    let misses = count(.miss)
    let stores = count(.store)
    let tombstones = lookups.filter { $0.outcome == .tombstone }
    let group = [cache.rawValue]
    let asked = hits + misses
    for (name, value) in [
      ("hits", hits), ("misses", misses), ("stores", stores), ("tombstones", tombstones.count),
    ] {
      metrics.append(
        EventSummaryMetric(
          name: name, group: group, value: Double(value), unit: .count, n: lookups.count))
    }

    var line = "\(cache.rawValue): "
    if asked > 0 {
      let rate = Double(hits) / Double(asked)
      metrics.append(
        EventSummaryMetric(name: "hit-rate", group: group, value: rate, unit: .share, n: asked))
      line += "hit rate \(Self.share(rate)) (\(hits) hits of \(asked) lookups, n=\(asked))"
    } else {
      line += "no lookups yet"
    }
    line += "; \(Self.plural(stores, "store")), \(Self.plural(tombstones.count, "tombstone"))"
    let reasons = EvidenceCacheTombstoneReason.allCases.compactMap { reason in
      let n = tombstones.count { $0.tombstoneReason == reason }
      return n > 0 ? "\(reason.rawValue) \(n)" : nil
    }
    if !reasons.isEmpty { line += " (\(reasons.joined(separator: ", ")))" }
    lines.append(line)

    staleKeys(cache, lookups, hits: hits, lines: &lines, metrics: &metrics)
  }

  /// A key that stored or served 2 different answers over time missed an input. The hits that
  /// served an answer the key later replaced are the stale hits that became visible.
  private func staleKeys(
    _ cache: CacheName, _ lookups: [CacheLookupEvent], hits: Int, lines: inout [String],
    metrics: inout [EventSummaryMetric]
  ) {
    var answers: [String: [String]] = [:]
    var keyOrder: [String] = []
    for lookup in lookups where lookup.outcome == .hit || lookup.outcome == .store {
      guard let answer = lookup.answerHash else { continue }
      if answers[lookup.keyHash] == nil { keyOrder.append(lookup.keyHash) }
      answers[lookup.keyHash, default: []].append(answer)
    }
    let stale = keyOrder.filter { Set(answers[$0] ?? []).count > 1 }
    var replacedHits: [String: Int] = [:]
    for lookup in lookups where lookup.outcome == .hit {
      guard let answer = lookup.answerHash, let last = answers[lookup.keyHash]?.last,
        answer != last
      else { continue }
      replacedHits[lookup.keyHash, default: 0] += 1
    }
    let replaced = replacedHits.values.reduce(0, +)
    let group = [cache.rawValue]
    metrics += [
      EventSummaryMetric(
        name: "stale-keys", group: group, value: Double(stale.count), unit: .count,
        n: keyOrder.count),
      EventSummaryMetric(
        name: "replaced-answer-hits", group: group, value: Double(replaced), unit: .count, n: hits),
    ]
    lines.append("  stale keys: \(stale.count) of \(keyOrder.count) keys (n=\(keyOrder.count))")
    guard !stale.isEmpty else { return }
    lines.append("  hits that served an answer the key later replaced: \(replaced) (n=\(hits))")
    for key in stale.prefix(Self.listedStaleKeys) {
      let distinct = Set(answers[key] ?? []).count
      lines.append(
        "    key \(key.prefix(12)): \(distinct) answers, "
          + "\(Self.plural(replacedHits[key] ?? 0, "hit")) on a replaced answer")
    }
    if stale.count > Self.listedStaleKeys {
      lines.append("    and \(stale.count - Self.listedStaleKeys) more")
    }
  }

  private static func share(_ value: Double) -> String {
    let hundredths = Int((value * 100).rounded())
    let fraction = hundredths % 100
    return "\(hundredths / 100).\(fraction < 10 ? "0" : "")\(fraction)"
  }

  private static func plural(_ count: Int, _ noun: String) -> String {
    "\(count) \(noun)\(count == 1 ? "" : "s")"
  }
}
