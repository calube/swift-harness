import Foundation
import SwiftGateDomain
import Testing

@Suite("Evidence cache records")
struct EvidenceCacheTests {
  private static func claim(kind: Citation.Kind, loc: String, pin: String?, quote: String? = "q")
    -> Claim
  {
    Claim(
      id: "ev-cache-record-under-test", lane: "packages", text: "Effect.run can be cancelled.",
      citation: Citation(kind: kind, loc: loc, pin: pin, quote: quote), status: .supported)
  }

  @Test(
    "claims without a usable pin or from a single run are refused — catches a cache file named by nothing or reused out of context"
  )
  func unusablePinsAndRunScopedKindsRefused() {
    let id = "ev-cache-record-under-test"
    #expect(throws: EvidenceCacheRefusal.missingPin(claimID: id)) {
      try ReusableClaim(Self.claim(kind: .snapshot, loc: "snapshots/a.md", pin: nil))
    }
    #expect(throws: EvidenceCacheRefusal.missingPin(claimID: id)) {
      try ReusableClaim(Self.claim(kind: .probe, loc: "probes/P.swift", pin: ""))
    }
    #expect(throws: EvidenceCacheRefusal.notReusable(claimID: id, kind: .answer)) {
      try ReusableClaim(Self.claim(kind: .answer, loc: "answers.jsonl#run/1", pin: nil))
    }
    #expect(throws: EvidenceCacheRefusal.invalidPin(claimID: id, pin: "ios/26")) {
      try ReusableClaim(Self.claim(kind: .snapshot, loc: "snapshots/a.md", pin: "ios/26"))
    }
  }

  @Test(
    "the fingerprint depends only on text and quote — catches a verdict keyed by claim id or location"
  )
  func fingerprintIsContentAddressed() throws {
    let first = try ReusableClaim(
      Self.claim(kind: .file, loc: ".build/checkouts/pkg/A.swift:L1-L2", pin: "pkg@1.0.0"))
    let moved = try ReusableClaim(
      Self.claim(kind: .file, loc: ".build/checkouts/pkg/B.swift:L9-L12", pin: "pkg@1.0.0"))
    let requoted = try ReusableClaim(
      Self.claim(
        kind: .file, loc: ".build/checkouts/pkg/A.swift:L1-L2", pin: "pkg@1.0.0", quote: "r"))
    #expect(first.fingerprint == moved.fingerprint)
    #expect(first.fingerprint != requoted.fingerprint)
    #expect(first.fingerprint.textHash.count == 64)
  }

  @Test(
    "records round-trip and an unknown origin or type fails to decode — catches an open vocabulary on a shared file"
  )
  func recordsAreClosed() throws {
    let claim = try ReusableClaim(
      Self.claim(kind: .file, loc: ".build/checkouts/pkg/A.swift:L1-L2", pin: "pkg@1.0.0"))
    let records: [EvidenceCacheRecord] = [
      .claim(claim, origin: .researchLane),
      .verdict(claim.fingerprint, verdict: .refuted, origin: .claimChecker),
      .reuse(claim.fingerprint),
      .tombstone(claim.fingerprint, reason: .amended),
    ]
    for record in records {
      let data = try JSONEncoder().encode(record)
      #expect(try JSONDecoder().decode(EvidenceCacheRecord.self, from: data) == record)
    }
    let unknownOrigin = Data(
      #"{"type":"verdict","textHash":"a","quoteHash":"b","verdict":"supported","origin":"web"}"#
        .utf8)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(EvidenceCacheRecord.self, from: unknownOrigin)
    }
    let unknownType = Data(#"{"type":"note","textHash":"a"}"#.utf8)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(EvidenceCacheRecord.self, from: unknownType)
    }
  }
}
