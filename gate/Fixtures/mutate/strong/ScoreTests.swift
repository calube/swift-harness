import ScoreCore
import Testing

@Test("the A band starts at exactly 90 — catches an off-by-one on the A boundary")
func aBoundary() {
  #expect(Score.grade(90) == "A")
  #expect(Score.grade(89) == "B")
}

@Test("the B band starts at exactly 70 — catches an off-by-one on the B boundary")
func bBoundary() {
  #expect(Score.grade(70) == "B")
  #expect(Score.grade(69) == "F")
}

@Test("passing starts at exactly 70 — catches the pass mark moving")
func passMark() {
  #expect(Score.isPassing(70))
  #expect(!Score.isPassing(69))
}
