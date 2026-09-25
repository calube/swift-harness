final class FrameRing: @unchecked Sendable { // swiftgate:allow safety.unchecked-sendable — every access holds `lock`; FrameRingTests hammers it from 8 tasks
}
final class Checked: Sendable {}
let note = "@unchecked Sendable needs a reason"
