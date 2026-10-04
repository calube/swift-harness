import Foundation
import SwiftGateDomain

/// The `error.code` values the pinned version was seen to print. A code outside this set fails
/// decoding and names itself, so an upgrade that adds one cannot pass as a known failure.
public enum AgentDeviceErrorCode: String, Sendable, Equatable, CaseIterable {
  case commandFailed = "COMMAND_FAILED"
  case deviceInUse = "DEVICE_IN_USE"
  case deviceNotFound = "DEVICE_NOT_FOUND"
  case sessionNotFound = "SESSION_NOT_FOUND"
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

  /// A wait that timed out, or a batch that stopped at a step, is evidence about the app. Every
  /// other failure is the driver's or the machine's.
  public var verdict: Verdict {
    switch self {
    case .failed(_, let failure)
    where failure.reason == .waitDeadlineExceeded || failure.failedStep != nil:
      .red
    case .runner, .failed, .unreadableOutput: .blocked
    }
  }

  public var message: String {
    switch self {
    case .runner(let command, let error): "agent-device \(command) could not run: \(error)"
    case .failed(let command, let failure):
      "agent-device \(command) failed (\(failure.code.rawValue)): \(failure.message)"
    case .unreadableOutput(let command, let status, let detail):
      "agent-device \(command) printed unexpected output (\(status)): \(detail)"
    }
  }

  /// Decodes the failure envelope `--json` prints on stdout.
  public static func decodeFailure(_ data: Data) throws(DecodingFailure) -> AgentDeviceFailure {
    struct Envelope: Decodable {
      struct Failure: Decodable {
        struct Details: Decodable {
          let reason: String?
          let step: Int?
          let command: String?
        }
        let code: String
        let message: String
        let details: Details?
      }
      let success: Bool
      let error: Failure
    }
    let envelope: Envelope
    do {
      envelope = try JSONDecoder().decode(Envelope.self, from: data)
    } catch {
      throw DecodingFailure(detail: "not a failure envelope: \(error)")
    }
    guard !envelope.success else {
      throw DecodingFailure(detail: "the envelope reports success")
    }
    guard let code = AgentDeviceErrorCode(rawValue: envelope.error.code) else {
      throw DecodingFailure(detail: "unknown error code \"\(envelope.error.code)\"")
    }
    let details = envelope.error.details
    var reason: AgentDeviceFailureReason?
    if let raw = details?.reason {
      guard let known = AgentDeviceFailureReason(rawValue: raw) else {
        throw DecodingFailure(detail: "unknown failure reason \"\(raw)\" for \(code.rawValue)")
      }
      reason = known
    }
    let failedStep = details.flatMap { details in
      details.step.flatMap { step in
        details.command.map { AgentDeviceBatchStep(index: step, command: $0) }
      }
    }
    return AgentDeviceFailure(
      code: code, message: envelope.error.message, reason: reason, failedStep: failedStep)
  }

  /// Why bytes did not decode, naming the value that broke them.
  public struct DecodingFailure: Error, Sendable, Equatable {
    public var detail: String

    public init(detail: String) {
      self.detail = detail
    }
  }
}
