import ScoreCore
import Testing

@Test("every score is an F before grading exists")
func ungraded() {
  #expect(Score.grade(100) == "F")
}
