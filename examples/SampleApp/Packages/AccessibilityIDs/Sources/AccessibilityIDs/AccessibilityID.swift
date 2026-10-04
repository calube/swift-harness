/// Every accessibility identifier the app sets. Views and UI tests both read these cases, so a
/// renamed or mistyped identifier fails to compile instead of failing a tap at runtime.
///
/// Give each case an explicit `"<screen>.<element>"` raw value: QA flow lint reads the raw values
/// from this file's source to check the `id="…"` selectors a flow names.
public enum AccessibilityID: String, CaseIterable, Sendable {
  case counterValue = "counter.value"
  case counterIncrement = "counter.increment"
  case counterDecrement = "counter.decrement"
  case counterFact = "counter.fact"
  case counterFactText = "counter.factText"
}
