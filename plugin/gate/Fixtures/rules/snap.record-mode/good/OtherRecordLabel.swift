import AVFoundation

struct Recorder {
  func start(_ session: Session) { session.begin(record: true) }
}
