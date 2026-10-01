/// The store's size per kind and stream, its sealed segments, dropped events and damage.
public struct StoreSection: EventSummarySection {
  public init() {}

  public var id: EventSummarySectionID { .store }

  public func summarize(_ input: EventSummaryInput) -> EventSummarySectionReport? {
    let store = input.store
    let streams = store.streams.filter { $0.activeBytes > 0 || $0.sealedSegments > 0 }
    let drops = store.dropped.dropped.flatMap { kind, reasons in
      reasons.map { (kind: kind.rawValue, reason: $0.key.rawValue, count: $0.value) }
    }.sorted { ($0.kind, $0.reason) < ($1.kind, $1.reason) }
    let dropped = drops.reduce(0) { $0 + $1.count }
    guard !input.events.isEmpty || !streams.isEmpty || dropped > 0 || !input.damage.isEmpty
    else { return nil }

    // Store-wide facts are counted over every store read.
    let stores = store.stores
    var metrics: [EventSummaryMetric] = []
    var lines = ["stores: \(stores) (this worktree's and \(max(0, stores - 1)) imported)"]
    let byKind = Dictionary(grouping: input.events, by: \.event.kind)
    let rolledUp = store.rolledUpTests
    for kind in HarnessEventKind.allCases {
      let counted = kind == .testResult ? rolledUp : nil
      guard byKind[kind] != nil || counted != nil else { continue }
      let events = byKind[kind] ?? []
      let bytes = events.reduce(counted?.bytes ?? 0) { $0 + $1.bytes }
      let n = events.count + (counted?.lines ?? 0)
      metrics.append(
        EventSummaryMetric(
          name: "bytes", group: [kind.rawValue], value: Double(bytes), unit: .bytes, n: n))
      lines.append("\(kind.rawValue): \(bytes) bytes (n=\(n))")
    }
    if let rolledUp {
      lines.append(
        "\(HarnessEventKind.testResult.rawValue) counted from \(rolledUp.segments) sealed segment "
          + "indexes; with --since, whole segments")
    }
    for stream in streams {
      let group = [stream.stream.rawValue]
      metrics += [
        EventSummaryMetric(
          name: "active-bytes", group: group, value: Double(stream.activeBytes), unit: .bytes,
          n: stores),
        EventSummaryMetric(
          name: "sealed-segments", group: group, value: Double(stream.sealedSegments),
          unit: .count, n: stores),
        EventSummaryMetric(
          name: "sealed-bytes", group: group, value: Double(stream.sealedBytes), unit: .bytes,
          n: stores),
      ]
      lines.append(
        "stream \(stream.stream.rawValue): \(stream.activeBytes) active bytes, "
          + "\(stream.sealedSegments) sealed segments in \(stream.sealedBytes) bytes")
    }
    for drop in drops {
      metrics.append(
        EventSummaryMetric(
          name: "dropped", group: [drop.kind, drop.reason], value: Double(drop.count),
          unit: .count, n: stores))
    }
    metrics.append(
      EventSummaryMetric(
        name: "dropped", group: [], value: Double(dropped), unit: .count, n: stores))
    lines.append(
      "dropped: \(dropped)"
        + (drops.isEmpty
          ? ""
          : " (" + drops.map { "\($0.kind) \($0.reason) \($0.count)" }.joined(separator: ", ")
            + ")"))
    metrics.append(
      EventSummaryMetric(
        name: "damaged", group: [], value: Double(input.damage.count), unit: .count, n: stores))
    lines.append("damaged lines and files: \(input.damage.count), listed under Damage")
    return EventSummarySectionReport(id: id, state: .reported, lines: lines, metrics: metrics)
  }
}
