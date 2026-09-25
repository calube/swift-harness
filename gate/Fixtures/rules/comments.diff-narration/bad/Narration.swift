// Previously this used a DispatchQueue.
let a = 1
// Now uses the shared formatter.
let b = 2
// Switched from filter to first(where:) in this PR
let c = 3
// Fixed bug where the badge count went negative.
let d = 4
/// This was previously computed on the main actor.
let e = 5
