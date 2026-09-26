func count(_ value: Any) -> Int? { value as? Int }
func widen(_ value: Int) -> Any { value as Any }
func known(_ value: Any) -> Int { value as! Int } // swiftgate:allow safety.as-bang — caller registers Int only; RegistryTests covers it
