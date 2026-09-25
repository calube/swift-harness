public func double(_ value: Int) -> Int {
  value * 2
}

public func half(_ value: Int) -> Int {
  if value < 0 {
    return -(-value / 2)
  }
  return value / 2
}
