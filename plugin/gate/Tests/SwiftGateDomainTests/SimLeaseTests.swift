import Foundation
import SwiftGateDomain
import Testing

@Suite("SimLease")
struct SimLeaseTests {
  static let lease = SimLease(
    runID: "20261004T120000Z-1a2b3c4d", worktree: "/repos/app-a", udid: "MADE-1",
    holderPID: 4242, session: nil)

  @Test(
    "a lease taken in worktree A checked from worktree B is otherWorktree naming A — catches a sibling worktree driving or releasing another worktree's device"
  )
  func otherWorktreeIsRefused() {
    #expect(
      SimLease.owner(of: Self.lease, callerWorktree: "/repos/app-b")
        == .otherWorktree(leaseWorktree: "/repos/app-a"))
    #expect(
      SimLease.owner(of: Self.lease, callerWorktree: "/repos/app-a/sub")
        == .otherWorktree(leaseWorktree: "/repos/app-a"))
    #expect(SimLease.owner(of: Self.lease, callerWorktree: "/repos/app-a") == .owner)
    #expect(SimLease.owner(of: Self.lease, callerWorktree: "/repos/app-a/") == .owner)
  }

  @Test(
    "a lease encodes to exactly its keys and decodes back, with and without a session — catches a lease that loses its session or holder on rewrite"
  )
  func roundTrip() throws {
    var withSession = Self.lease
    withSession.session = "qa-1a2b3c4d"
    for lease in [Self.lease, withSession] {
      let data = lease.encoded()
      #expect(try SimLease.decode(data) == lease)
      let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
      let expected: Set<String> =
        lease.session == nil
        ? ["runID", "worktree", "udid", "holderPID"]
        : ["runID", "worktree", "udid", "holderPID", "session"]
      #expect(Set(object.keys) == expected)
    }
  }

  @Test(
    "a lease with an unknown key, a missing key, an empty session or a zero PID fails naming it — catches a half-written or foreign lease read as valid"
  )
  func closedDecoding() {
    func decode(_ json: String) -> SimLeaseDecodingError? {
      do {
        _ = try SimLease.decode(Data(json.utf8))
        return nil
      } catch {
        return error
      }
    }
    let base = #""runID":"r1","worktree":"/w","udid":"U","holderPID":7"#
    #expect(decode("{\(base),\"owner\":\"x\"}") == .unknownKey("owner"))
    #expect(decode(#"{"runID":"r1","worktree":"/w","holderPID":7}"#) == .missingKey("udid"))
    #expect(decode("{\(base),\"session\":\"\"}") == .invalidValue(key: "session", value: ""))
    #expect(
      decode(#"{"runID":"r1","worktree":"/w","udid":"U","holderPID":0}"#)
        == .invalidValue(key: "holderPID", value: "0"))
    #expect(decode("[]").map { if case .malformed = $0 { true } else { false } } == true)
    #expect(decode("{\(base)}") == nil)
  }

  @Test(
    "a run id must be one plain file name — catches a run id that writes a lease outside the lease directory"
  )
  func runIDIsAFileName() {
    #expect(SimLease.isValidRunID("20261004T120000Z-1a2b3c4d"))
    for bad in ["", "a/b", "../x", ".hidden", "a b", "x\n"] {
      #expect(!SimLease.isValidRunID(bad), "\(bad.debugDescription) accepted")
    }
  }

  @Test(
    "the holder gives the device back when the lease is removed, the recorded session is gone, or the timeout passes, and only then — catches a holder that never frees its slot, or frees it while the run is live"
  )
  func holdWatch() {
    var recorded = Self.lease
    recorded.session = "qa-1"
    let timeout = Duration.seconds(60)

    #expect(
      SimHoldWatch.end(lease: nil, liveSessions: nil, elapsed: .zero, timeout: timeout)
        == .released)
    #expect(
      SimHoldWatch.end(lease: recorded, liveSessions: ["other"], elapsed: .zero, timeout: timeout)
        == .sessionGone(session: "qa-1"))
    #expect(
      SimHoldWatch.end(lease: recorded, liveSessions: nil, elapsed: .seconds(60), timeout: timeout)
        == .timedOut(after: timeout))

    #expect(
      SimHoldWatch.end(lease: recorded, liveSessions: ["qa-1"], elapsed: .zero, timeout: timeout)
        == nil)
    #expect(
      SimHoldWatch.end(lease: recorded, liveSessions: nil, elapsed: .seconds(59), timeout: timeout)
        == nil)
    #expect(
      SimHoldWatch.end(lease: Self.lease, liveSessions: [], elapsed: .zero, timeout: timeout)
        == nil, "a session not yet recorded can't be gone")
  }
}
