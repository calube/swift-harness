import Foundation
import SwiftGateDomain

/// The `error.code` values the pinned version was seen to print. A code outside this set fails
/// decoding and names itself, so an upgrade that adds one cannot pass as a known failure.
public enum AgentDeviceErrorCode: String, Sendable, Equatable, CaseIterable {
  case commandFailed = "COMMAND_FAILED"
  case deviceInUse = "DEVICE_IN_USE"
  case deviceNotFound = "DEVICE_NOT_FOUND"
  case invalidArgs = "INVALID_ARGS"
}

/// The `error.details.reason` values the pinned version was seen to print.
public enum AgentDeviceFailureReason: String, Sendable, Equatable, CaseIterable {
  case waitDeadlineExceeded = "wait_deadline_exceeded"
}

/// The batch step that stopped a batch: its 1-based index and its command.
public struct AgentDeviceBatchStep: Sendable, Equatable {
  public var index: Int
  public var command: String

  public init(index: Int, command: String) {
    self.index = index
    self.command = command
  }
}

/// A typed failure `agent-device --json` printed.
public struct AgentDeviceFailure: Sendable, Equatable {
  public var code: AgentDeviceErrorCode
  public var message: String
  public var reason: AgentDeviceFailureReason?
  /// Set only when a batch stopped at a step.
  public var failedStep: AgentDeviceBatchStep?

  public init(
    code: AgentDeviceErrorCode, message: String, reason: AgentDeviceFailureReason? = nil,
    failedStep: AgentDeviceBatchStep? = nil
  ) {
    self.code = code
    self.message = message
    self.reason = reason
    self.failedStep = failedStep
  }
}

public enum AgentDeviceError: Error, Sendable, Equatable {
  case runner(command: String, ProcessRunnerError)
  /// `agent-device` reported a typed failure.
  case failed(command: String, AgentDeviceFailure)
  /// The output was neither the success nor the failure shape the pinned version prints.
  case unreadableOutput(command: String, status: ExitStatus, detail: String)

  public var verdict: Verdict { .blocked }

  public var message: String { "" }

  /// Decodes the failure envelope `--json` prints on stdout.
  public static func decodeFailure(_ data: Data) throws(DecodingFailure) -> AgentDeviceFailure {
    throw DecodingFailure(detail: "")
  }

  /// Why bytes did not decode, naming the value that broke them.
  public struct DecodingFailure: Error, Sendable, Equatable {
    public var detail: String

    public init(detail: String) {
      self.detail = detail
    }
  }
}
