import ScoreCore
import Testing

@Test("a top score is an A — catches grading losing the A band")
func topScore() {
  #expect(Score.grade(95) == "A")
}

@Test("a perfect score passes — catches passing never being reported")
func perfectPasses() {
  #expect(Score.isPassing(100))
}
