import Testing

@Test("SUT reads the mock — catches the loader ignoring the API")
func loaderUsesAPI() async {
  let api = MockAPIClient()
  api.fetchResult = 42
  let loader = Loader(api: api)
  #expect(await loader.load() == 42)
}

@Test("spy records the SUT's call — catches a missing save")
func spyRecords() {
  let store = SpyStore()
  Saver(store: store).save("a")
  #expect(store.saved == ["a"])
}
