import Foundation
import SwiftGateDomain

/// 1 transcript file's bytes and whose they are.
public struct TranscriptFile: Sendable, Equatable {
  public let agent: UsageAgent
  /// From `agent-<id>.jsonl`; `nil` for the session's own transcript.
  public let agentID: String?
  /// What a message about the file names: its file name, never its path.
  public let label: String
  public let data: Data

  public init(agent: UsageAgent, agentID: String?, label: String, data: Data) {
    self.agent = agent
    self.agentID = agentID
    self.label = label
    self.data = data
  }
}

/// Why a transcript couldn't be read.
public struct TranscriptReadError: Error, Sendable, Equatable, CustomStringConvertible {
  public let description: String

  public init(_ description: String) {
    self.description = description
  }
}

/// Reads Claude Code transcripts where Claude Code wrote them.
public struct TranscriptReader: Sendable {
  public init() {}

  /// The session's transcript at `path`, then each `agent-*.jsonl` in the `subagents` directory
  /// beside it.
  public func session(at path: URL) throws(TranscriptReadError) -> [TranscriptFile] {
    []
  }

  /// Each `agent-*.jsonl` directly in `directory`, sorted by name.
  public func workflow(in directory: URL) throws(TranscriptReadError) -> [TranscriptFile] {
    []
  }
}
