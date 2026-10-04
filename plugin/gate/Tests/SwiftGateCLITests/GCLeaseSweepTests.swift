import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@testable import SwiftGateCLI

@Suite("gc frees the leases dead holders leave")
struct GCLeaseSweepTests {
  @Test(
    "gc sweeps leases before orphan clones, lists each released run, and makes each lease problem an error — catches gc skipping a killed holder's lease, or sweeping clones first so the session can't be closed on its device"
  )
  func sweepsLeasesFirst() async throws {
    let root = try TestTemporaryDirectory.make("gc-leases")
    defer { TestTemporaryDirectory.remove(root) }
    let order = Mutex<[String]>([])

    let summary = await GCRun.run(
      root: root, maxAgeDays: 7, now: Date(),
      sweepLeases: {
        order.withLock { $0.append("leases") }
        return SimLeaseSweep(
          released: ["20261004T120000Z-dead0001"],
          problems: ["run 20261004T120500Z-dead0002: close failed"],
          notes: ["unreadable lease skipped: x"])
      },
      sweepOrphans: {
        order.withLock { $0.append("clones") }
        return []
      })

    #expect(order.withLock { $0 } == ["leases", "clones"])
    #expect(summary.releasedLeases == ["20261004T120000Z-dead0001"])
    #expect(summary.errors == ["run 20261004T120500Z-dead0002: close failed"])

    let human = try GCRun.render(summary, format: .human, maxAgeDays: 7)
    #expect(human.contains("1 dead holder lease(s)"))
    #expect(human.contains("released run 20261004T120000Z-dead0001"))
    let json = try GCRun.render(summary, format: .json, maxAgeDays: 7)
    #expect(json.contains("\"releasedLeases\""))
  }
}
