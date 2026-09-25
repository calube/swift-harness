func price(raw: Int, currency: Currency) -> Int {
  // The API returns prices in minor units for every currency except JPY.
  if currency == .jpy { return raw }
  // Rounding toward zero matches the receipt printer.
  return raw / 100

  // Unrelated note separated by a blank line.

  return raw
}
