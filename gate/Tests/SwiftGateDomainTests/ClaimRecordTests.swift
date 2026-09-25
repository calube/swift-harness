import Foundation
import SwiftGateDomain
import Testing

@Suite("Claim record")
struct ClaimRecordTests {
  private static let sampleCitation = Citation(
    kind: .file,
    loc:
      ".build/checkouts/swift-composable-architecture/Sources/ComposableArchitecture/Effects/Cancellation.swift:L40-L52",
    pin: "swift-composable-architecture@1.26.2",
    quote:
      "public func cancellable<ID: Hashable & Sendable>(id: ID, cancelInFlight: Bool = false) -> Self"
  )

  private static let sampleClaim = Claim(
    id: "ev-tca-effect-run-supports-cancellation",
    lane: "packages",
    text: "Effect.run returns an effect that can be cancelled by id via .cancellable(id:).",
    citation: sampleCitation,
    status: .supported
  )

  @Test("claim JSONL round-trips byte-stable — catches schema drift")
  func jsonlRoundTrip() throws {
    let firstPass = try ClaimJSON.encodeLine(Self.sampleClaim)
    let (decoded, invalid) = ClaimJSON.decode(firstPass)
    #expect(invalid == 0)
    #expect(decoded == [Self.sampleClaim])
    let secondPass = try ClaimJSON.encodeLine(decoded[0])
    #expect(firstPass == secondPass)
  }

  @Test(
    "quote-fail cannot transition to supported — catches a mechanical fail laundered by the checker"
  )
  func quoteFailCannotBecomeSupported() {
    #expect(
      !ClaimStatusMachine.canTransition(from: .quoteFail, to: .supported, citationKind: .file))
    #expect(!ClaimStatusMachine.canTransition(from: .quoteFail, to: .refuted, citationKind: .file))
  }

  @Test("any status can transition to stale")
  func anyStatusCanGoStale() {
    for status in Claim.Status.allCases {
      #expect(ClaimStatusMachine.canTransition(from: status, to: .stale, citationKind: .file))
      #expect(ClaimStatusMachine.canTransition(from: status, to: .stale, citationKind: .probe))
    }
  }

  @Test("probe claims take the probe verdict directly, skipping the quote stage")
  func probeClaimsBypassQuoteStage() {
    #expect(ClaimStatusMachine.canTransition(from: .new, to: .supported, citationKind: .probe))
    #expect(ClaimStatusMachine.canTransition(from: .new, to: .refuted, citationKind: .probe))
    #expect(!ClaimStatusMachine.canTransition(from: .new, to: .quoteOk, citationKind: .probe))
    #expect(!ClaimStatusMachine.canTransition(from: .new, to: .supported, citationKind: .file))
  }

  @Test("the opus checker judges a quote-ok claim into supported or refuted")
  func quoteOkCanBeJudged() {
    #expect(ClaimStatusMachine.canTransition(from: .quoteOk, to: .supported, citationKind: .file))
    #expect(ClaimStatusMachine.canTransition(from: .quoteOk, to: .refuted, citationKind: .file))
  }

  @Test("a claim cannot transition to its own new status — catches a no-op laundered as progress")
  func newCannotStayNew() {
    #expect(!ClaimStatusMachine.canTransition(from: .new, to: .new, citationKind: .file))
  }

  @Test("a torn claim line is counted as invalid rather than failing the whole file")
  func claimDecodeCountsInvalidLines() throws {
    let goodLine = try ClaimJSON.encodeLine(Self.sampleClaim)
    var data = goodLine
    data.append(contentsOf: Array("{not json".utf8))
    data.append(UInt8(ascii: "\n"))
    let (claims, invalid) = ClaimJSON.decode(data)
    #expect(claims == [Self.sampleClaim])
    #expect(invalid == 1)
  }

  @Test("a 2-word claim id is rejected — catches ids that don't carry ≥3 words of meaning")
  func twoWordIdRejected() {
    #expect(!IdPolicy.isValid("ev-foo-bar", kind: .claim))
    #expect(IdPolicy.isValid("ev-foo-bar-baz", kind: .claim))
  }

  @Test("an -R1 style revision suffix is rejected — catches per-revision id namespacing")
  func revisionSuffixRejected() {
    #expect(!IdPolicy.isValid("ev-foo-bar-baz-r1", kind: .claim))
    #expect(!IdPolicy.isValid("req-foo-bar-baz-r12", kind: .requirement))
  }

  @Test("a clarify amendment record with a review is rejected")
  func clarifyWithReviewRejected() {
    let clarifyWithReview = Amendment(
      title: "retry queue drains in batches of 20",
      at: Date(timeIntervalSince1970: 0),
      class: .clarify,
      fromSha: "3f1c",
      toSha: "9b0e",
      changedIds: ["req-offline-queue-drains-on-reconnect"],
      newClaims: [],
      trigger: "design-conflict",
      review: Amendment.Review(verdict: "ready", reviewers: ["evidence-auditor"]),
      approval: nil
    )
    #expect(!Amendment.isValid(clarifyWithReview))

    let plainClarify = Amendment(
      title: "retry queue drains in batches of 20",
      at: Date(timeIntervalSince1970: 0),
      class: .clarify,
      fromSha: "3f1c",
      toSha: "9b0e",
      changedIds: ["req-offline-queue-drains-on-reconnect"],
      newClaims: [],
      trigger: "design-conflict",
      review: nil,
      approval: nil
    )
    #expect(Amendment.isValid(plainClarify))
  }

  @Test("amendment JSONL round-trips byte-stable — catches schema drift")
  func amendmentJSONLRoundTrip() throws {
    let amendment = Amendment(
      title: "retry queue drains in batches of 20",
      at: Date(timeIntervalSince1970: 1_790_236_800),
      class: .amend,
      fromSha: "3f1c",
      toSha: "9b0e",
      changedIds: [
        "req-offline-queue-drains-on-reconnect", "test-queued-orders-replay-in-submit-order",
      ],
      newClaims: ["ev-urlsession-background-task-limit-per-session"],
      trigger: "design-conflict from task offline-queue-core-reducer",
      review: Amendment.Review(
        verdict: "ready", reviewers: ["evidence-auditor", "standards-conformance"]),
      approval: Amendment.Approval(
        decision: "approve", designSha: "9b0e", at: Date(timeIntervalSince1970: 1_790_240_000))
    )
    let firstPass = try AmendmentJSON.encodeLine(amendment)
    let (decoded, invalid) = AmendmentJSON.decode(firstPass)
    #expect(invalid == 0)
    #expect(decoded == [amendment])
    let secondPass = try AmendmentJSON.encodeLine(decoded[0])
    #expect(firstPass == secondPass)
  }

  @Test("a torn amendment line is counted as invalid rather than failing the whole file")
  func amendmentDecodeCountsInvalidLines() throws {
    let amendment = Amendment(
      title: "retry queue drains in batches of 20",
      at: Date(timeIntervalSince1970: 0),
      class: .clarify,
      fromSha: "3f1c",
      toSha: "9b0e",
      changedIds: [],
      newClaims: [],
      trigger: "design-conflict",
      review: nil,
      approval: nil
    )
    var data = try AmendmentJSON.encodeLine(amendment)
    data.append(contentsOf: Array("{not json".utf8))
    data.append(UInt8(ascii: "\n"))
    let (amendments, invalid) = AmendmentJSON.decode(data)
    #expect(amendments == [amendment])
    #expect(invalid == 1)
  }

  @Test("an ADR slug is a 4-digit number then kebab words")
  func adrSlugForm() {
    #expect(IdPolicy.isValidADRSlug("0004-queue-orders-in-a-client-module"))
    #expect(!IdPolicy.isValidADRSlug("4-queue-orders-in-a-client-module"))
    #expect(!IdPolicy.isValidADRSlug("0004-"))
    #expect(!IdPolicy.isValidADRSlug("0004"))
    #expect(!IdPolicy.isValidADRSlug("0004-Queue-Orders"))
  }

  @Test("evidence layout derives the sibling directory and its committed files")
  func evidenceLayout() {
    let layout = EvidenceLayout(designDocPath: "docs/ordering/designs/offline-order-queue.md")
    #expect(layout.root == "docs/ordering/designs/offline-order-queue.evidence")
    #expect(layout.claimsFile == "docs/ordering/designs/offline-order-queue.evidence/claims.jsonl")
    #expect(
      layout.amendmentsFile == "docs/ordering/designs/offline-order-queue.evidence/amendments.jsonl"
    )
    #expect(
      layout.snapshotsDirectory == "docs/ordering/designs/offline-order-queue.evidence/snapshots")
    #expect(
      layout.capturesDirectory == "docs/ordering/designs/offline-order-queue.evidence/captures")
    #expect(layout.probesDirectory == "docs/ordering/designs/offline-order-queue.evidence/probes")
  }
}
