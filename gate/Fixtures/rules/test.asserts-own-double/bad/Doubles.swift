import Testing

@Test("mock returns what it was told — catches nothing")
func mockEcho() {
  let api = MockAPIClient()
  api.fetchResult = 42
  #expect(api.fetchResult == 42)
}

@Test("stub built and read back — catches nothing")
func stubEcho() {
  let clock = StubClock(now: 100)
  #expect(clock.now == 100)
}
