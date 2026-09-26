// swiftlint:disable:next force_cast — the registry only stores Strings under this key
let a = value as! String // swiftgate:allow safety.as-bang — registry stores Strings only
let b = try! load() // swiftgate:allow safety.try-bang — bundled resource; LoaderTests loads it
final class Ring: @unchecked Sendable {} // swiftgate:allow safety.unchecked-sendable — lock guards all state
nonisolated(unsafe) var counter = 0 // swiftgate:allow safety.nonisolated-unsafe — written once before launch
@preconcurrency import LegacyKit // swiftgate:allow safety.preconcurrency — vendor SDK predates Sendable
// swiftlint:enable force_cast
let c = try? load()
let d = value as? Int
let e = "try! as! @unchecked Sendable"
