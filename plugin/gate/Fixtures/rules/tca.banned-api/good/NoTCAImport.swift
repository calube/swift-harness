import AVFoundation

struct TaskResult {}
final class Recorder {
  var isRecording = false
  func toggle() { isRecording = !isRecording }
}
