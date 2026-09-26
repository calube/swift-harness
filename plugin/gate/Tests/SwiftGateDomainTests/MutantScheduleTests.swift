import SwiftGateDomain
import Testing

@Suite("mutant schedule")
struct MutantScheduleTests {
  @Test(
    "workers keep to packages they have built and fan out to unclaimed ones first — catches every worker cold-building every package"
  )
  func affinity() {
    var schedule = MutantSchedule(jobPackages: [["A"], ["A"], ["A"], ["B"], ["B"], ["B"]])

    #expect(schedule.next(worker: 1) == 0)
    #expect(schedule.next(worker: 2) == 3)
    #expect(schedule.next(worker: 1) == 1)
    #expect(schedule.next(worker: 2) == 4)
    #expect(schedule.next(worker: 2) == 5)
    #expect(schedule.next(worker: 1) == 2)
    #expect(schedule.next(worker: 1) == nil)
    #expect(schedule.next(worker: 2) == nil)
  }

  @Test(
    "an idle worker takes over a package only when two or more of its mutants are left — catches a cold build spent on a mutant its owner is about to reach"
  )
  func stealing() {
    var schedule = MutantSchedule(jobPackages: [["A"], ["A"], ["A"], ["A"], ["B"]])

    #expect(schedule.next(worker: 1) == 0)
    #expect(schedule.next(worker: 2) == 4)
    // Worker 2 has built only B, which is done; A still has 3 mutants waiting.
    #expect(schedule.next(worker: 2) == 1)
    #expect(schedule.next(worker: 1) == 2)
    // One A mutant left: worker 3, with nothing built, does not start a cold build for it.
    #expect(schedule.next(worker: 3) == nil)
    #expect(schedule.next(worker: 2) == 3)
    #expect(schedule.next(worker: 1) == nil)
  }

  @Test(
    "a mutant needing several packages goes to a worker that built them all — catches a mutant in a shared client re-building its dependants in a fresh worker"
  )
  func multiPackageJobs() {
    var schedule = MutantSchedule(jobPackages: [["A", "B"], ["B"], ["A", "B"]])

    #expect(schedule.next(worker: 1) == 0)
    // B is claimed by worker 1 through job 0; worker 2 would steal, but only one B-only job waits.
    #expect(schedule.next(worker: 2) == nil)
    #expect(schedule.next(worker: 1) == 1)
    #expect(schedule.next(worker: 1) == 2)
    #expect(schedule.next(worker: 1) == nil)
  }

  @Test(
    "a mutant no single worker has built every package for is still handed out — catches a mutant left unjudged as \"no worker ran this mutant\""
  )
  func noStarvation() {
    var schedule = MutantSchedule(jobPackages: [["A"], ["B"], ["A", "B"]])

    #expect(schedule.next(worker: 1) == 0)
    #expect(schedule.next(worker: 2) == 1)
    #expect(schedule.next(worker: 1) == 2)
    #expect(schedule.next(worker: 2) == nil)
    #expect(schedule.next(worker: 1) == nil)
  }

  @Test(
    "a worker that stopped on a failure no longer covers its packages — catches mutants stranded behind a worker whose tree broke"
  )
  func stoppedWorkersDoNotCover() {
    var schedule = MutantSchedule(jobPackages: [["A"], ["A"]])

    #expect(schedule.next(worker: 1) == 0)
    // Worker 1 will reach the last A mutant itself.
    #expect(schedule.next(worker: 2) == nil)
    schedule.finish(worker: 1)
    #expect(schedule.next(worker: 3) == 1)
  }
}
