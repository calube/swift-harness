/// Which mutant a worker takes next. A worker's first build of a package is cold (minutes for a
/// package over TCA) and every later one incremental, so a worker stays with the packages it has
/// built, an idle worker starts on a package nobody has built yet, and only then takes over
/// another worker's package: when at least two of its mutants are left, since for one the owner
/// is about as quick as a cold build. A mutant no running worker can take without a cold build
/// is always handed out, so none is left unjudged.
public struct MutantSchedule: Sendable {
  private let jobPackages: [Set<String>]
  private var pending: [Int]
  private var claimed: Set<String> = []
  private var built: [Int: Set<String>] = [:]
  private var finished: Set<Int> = []

  /// - Parameter jobPackages: per job, the packages whose builds its tests need.
  public init(jobPackages: [Set<String>]) {
    self.jobPackages = jobPackages
    pending = Array(jobPackages.indices)
  }

  /// The index of the job `worker` takes, or `nil` when it should stop.
  public mutating func next(worker: Int) -> Int? {
    guard let job = choose(worker: worker) else {
      finished.insert(worker)
      return nil
    }
    return job
  }

  /// `worker` takes no more jobs; the packages it built no longer count as covered.
  public mutating func finish(worker: Int) { finished.insert(worker) }

  private mutating func choose(worker: Int) -> Int? {
    let own = built[worker, default: []]
    if let position = pending.firstIndex(where: { jobPackages[$0].isSubset(of: own) }) {
      return take(position, worker: worker)
    }
    if let position = pending.firstIndex(where: { jobPackages[$0].isDisjoint(with: claimed) }) {
      return take(position, worker: worker)
    }
    let covering = built.filter { $0.key != worker && !finished.contains($0.key) }.values
    if let position = pending.firstIndex(where: { job in
      !covering.contains { jobPackages[job].isSubset(of: $0) }
    }) {
      return take(position, worker: worker)
    }
    var waiting: [Set<String>: Int] = [:]
    for job in pending { waiting[jobPackages[job], default: 0] += 1 }
    guard let busiest = waiting.max(by: { $0.value < $1.value }), busiest.value >= 2,
      let position = pending.firstIndex(where: { jobPackages[$0] == busiest.key })
    else { return nil }
    return take(position, worker: worker)
  }

  private mutating func take(_ position: Int, worker: Int) -> Int {
    let job = pending.remove(at: position)
    claimed.formUnion(jobPackages[job])
    built[worker, default: []].formUnion(jobPackages[job])
    return job
  }
}
