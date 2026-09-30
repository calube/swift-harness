import SwiftGateDomain

/// The Jev model this harness pins, and its price. They sit together so a pin bump forces a look
/// at the price: a test fails when the captured served model differs from `model`.
public enum JevPin {
  /// Config owns the pin. `JudgeBackend.jev` always has a pin, a key variable and a host; the
  /// domain's optionals are for backends without them.
  public static let model = JudgeBackend.jev.pinnedModel!
  /// USD per million input tokens for `model`, from TypeSafe's models page on 2026-09-30. Output
  /// tokens are free, and Jev's reply carries no cost of its own.
  public static let pricePerMillionInputTokens = 0.042
  /// The environment variable holding the API key. Config never holds the key.
  public static let keyVariable = JudgeBackend.jev.keyVariable!
  /// The request goes to the host `[judge] send_to` must name.
  public static let endpoint = "https://\(JudgeBackend.jev.egressHost!)/v1/systemone"
}
