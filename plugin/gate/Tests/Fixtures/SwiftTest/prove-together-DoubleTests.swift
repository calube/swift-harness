import Lib
import Testing

struct DoubleTests {
  @Test func doublesThree() { #expect(double(3) == 6) }
  @Test func doublesFour() { #expect(double(4) == 8) }
  @Test func keepsZero() { #expect(double(0) == 0) }
}
