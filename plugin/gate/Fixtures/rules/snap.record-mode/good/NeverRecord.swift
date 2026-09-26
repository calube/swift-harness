import SnapshotTesting
import Testing

@Suite(.snapshots(record: .never))
struct CounterSnapshots {
  @Test func counter() {
    assertSnapshot(of: view, as: .image)
    assertSnapshot(of: view, as: .image, record: nil)
    withSnapshotTesting(record: SnapshotTestingConfiguration.Record.never) {}
    let note = "record: .all is banned"
  }
}
