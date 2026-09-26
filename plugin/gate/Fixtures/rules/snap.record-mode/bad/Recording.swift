import SnapshotTesting
import Testing

@Suite(.snapshots(record: .missing))
struct CounterSnapshots {
  @Test func counter() {
    assertSnapshot(of: view, as: .image, record: true)
    assertSnapshot(of: view, as: .image, record: false)
    withSnapshotTesting(record: .all) { assertSnapshot(of: view, as: .image) }
    withSnapshotTesting(record: .failed) {}
  }
}
