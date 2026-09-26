struct Feed {
  func debug(_ items: [Int]) {
    print("items", items)
    debugPrint(items)
    Swift.print(items.count)
    dump(items)
  }
  func legacy() { NSLog("loaded") }
}
