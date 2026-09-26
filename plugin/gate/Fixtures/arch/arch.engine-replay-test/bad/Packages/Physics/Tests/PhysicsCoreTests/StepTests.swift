import PhysicsCore
import Testing

@Test("one step moves by velocity times dt — catches a frozen integrator")
func stepMoves() {
  #expect(step(0, velocity: 2, dt: 0.5) == 1)
}
