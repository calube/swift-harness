import SwiftGateDomain

/// The per-backend recordings the harness ships under `gate/Fixtures/judge/`.
public enum JudgeCalibrationFiles {
  /// Claude's recording keeps its original name; every other backend's is `recording-<backend>.json`.
  public static func recordingFile(for backend: JudgeBackend) -> String {
    switch backend {
    case .claude: "recording.json"
    case .jev: "recording-jev.json"
    }
  }
}
