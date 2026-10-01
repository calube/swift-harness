import Foundation
import SwiftGateDomain
import Testing

@Suite("cache lookup hashes")
struct CacheLookupHashTests {
  private static func claim(id: String, loc: String = "L40-L52") throws -> Claim {
    Claim(
      id: id, lane: "packages", text: "Effect.run starts a long-living effect.",
      citation: Citation(
        kind: .file,
        loc: ".build/checkouts/swift-composable-architecture/Sources/Effect.swift:\(loc)",
        pin: "swift-composable-architecture@1.26.2", quote: "public static func run("),
      status: .supported)
  }

  private static func isSHA256Hex(_ text: String) -> Bool {
    text.count == 64 && text.allSatisfy { "0123456789abcdef".contains($0) }
  }

  @Test(
    "an evidence key is a SHA-256 that differs by file and by fingerprint — catches 2 pins or 2 quotes sharing 1 key"
  )
  func evidenceKeys() {
    let fingerprint = EvidenceFingerprint(text: "a", quote: "b")
    let keys = [
      CacheLookupHash.evidenceKey(bucket: .package(pin: "p@1"), fingerprint: fingerprint),
      CacheLookupHash.evidenceKey(bucket: .package(pin: "p@2"), fingerprint: fingerprint),
      CacheLookupHash.evidenceKey(bucket: .sdk(pin: "p@1"), fingerprint: fingerprint),
      CacheLookupHash.evidenceKey(bucket: .verdicts, fingerprint: fingerprint),
      CacheLookupHash.evidenceKey(
        bucket: .verdicts, fingerprint: EvidenceFingerprint(text: "a", quote: "c")),
      CacheLookupHash.evidenceKey(
        bucket: .verdicts, fingerprint: EvidenceFingerprint(text: "a", quote: nil)),
    ]

    #expect(keys.allSatisfy(Self.isSHA256Hex))
    #expect(Set(keys).count == keys.count)
  }

  @Test(
    "a claim's answer hash survives the cache line round-trip and changes with the citation — catches a hit's hash that never matches its store"
  )
  func claimAnswerHash() throws {
    let claim = try Self.claim(id: "ev-effect-run")
    let line = try JSONEncoder().encode(
      EvidenceCacheRecord.claim(try ReusableClaim(claim), origin: .researchLane))
    guard
      case .claim(let decoded, _) = try JSONDecoder().decode(EvidenceCacheRecord.self, from: line)
    else {
      Issue.record("the cache line decoded as another record")
      return
    }

    let stored = try #require(CacheLookupHash.answer(claim: claim))
    #expect(Self.isSHA256Hex(stored))
    #expect(CacheLookupHash.answer(claim: decoded.claim) == stored)
    #expect(
      CacheLookupHash.answer(claim: try Self.claim(id: "ev-effect-run", loc: "L1-L2")) != stored)
  }

  @Test("a verdict's answer hash tells supported from refuted — catches 1 hash for every verdict")
  func verdictAnswerHash() {
    let supported = CacheLookupHash.answer(verdict: .supported)
    let refuted = CacheLookupHash.answer(verdict: .refuted)

    #expect(Self.isSHA256Hex(supported))
    #expect(supported != refuted)
  }
}
