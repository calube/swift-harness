public func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
  min(max(value, range.lowerBound), range.upperBound)
}
