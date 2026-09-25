// The cache is shared across scenes.
let a = 1
// The reducer never touches the network — clients do.
let b = 2
let c = try! load() // swiftgate:allow safety.try-bang — bundled resource; em dash is the separator
let d = "It's worth noting that strings are not comments"
