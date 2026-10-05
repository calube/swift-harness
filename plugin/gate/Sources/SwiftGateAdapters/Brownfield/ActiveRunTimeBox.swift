import Foundation
import SwiftGateDomain

/// The time box of the `swiftgate run` going on in a clone, read from each plan's launch clock.
public enum ActiveRunTimeBox {
  /// The box that has started and not ended at `now`; of several, the latest launched, with its
  /// final reserve grown to hold `finalSeconds`. `nil` when no plan's clock holds one. A clock
  /// that can't be read is skipped: a gate with no box runs to its measured bounds.
  public static func find(layout: BrownfieldStateLayout, now: Date, finalSeconds: Int? = nil)
    -> RunTimeBox?
  {
    let plans =
      (try? FileManager.default.contentsOfDirectory(
        at: layout.plansDirectory, includingPropertiesForKeys: nil)) ?? []
    return
      plans
      .compactMap { plan -> RunTimeBox? in
        guard let data = try? Data(contentsOf: plan.appending(path: RunClock.fileName)) else {
          return nil
        }
        return try? RunClock.decode(data).runTimeBox.map { box in
          RunTimeBox(
            startedAt: box.startedAt, limits: box.limits.holding(finalSeconds: finalSeconds))
        }
      }
      .filter { $0.startedAt <= now && now < $0.deadlines.endsAt }
      .max { $0.startedAt < $1.startedAt }
  }
}

/// The clone's gate history, read for how long its `final` gate takes.
public enum MeasuredFinalGateReader {
  /// ``MeasuredFinalGate/seconds(in:)`` over the gate runs recorded where `worktree`'s events
  /// go; `nil` when none can be read.
  public static func seconds(worktree: URL) -> Int? {
    guard let data = try? HarnessEventFiles(root: worktree).read(.gate, runID: nil),
      let read = try? HarnessEventJSON.decode(data)
    else { return nil }
    return MeasuredFinalGate.seconds(
      in: read.events.compactMap { event in
        guard case .gateRun(let run) = event.payload else { return nil }
        return run
      })
  }

  /// Each `gate.run` recorded where `worktree`'s events go, its duration in milliseconds by run
  /// id; empty when none can be read.
  public static func milliseconds(worktree: URL) -> [String: Int] {
    guard let data = try? HarnessEventFiles(root: worktree).read(.gate, runID: nil),
      let read = try? HarnessEventJSON.decode(data)
    else { return [:] }
    var durations: [String: Int] = [:]
    for event in read.events {
      guard case .gateRun(let run) = event.payload, let id = event.runID else { continue }
      durations[id] = run.milliseconds
    }
    return durations
  }
}
