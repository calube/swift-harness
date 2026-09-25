func count(_ value: Any) -> Int { value as! Int }
func cell(_ view: AnyObject) -> String { (view as! CustomStringConvertible).description }
