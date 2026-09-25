import PhysicsCore
import Testing

@Test("the same inputs replay to the same position — catches hidden nondeterminism in the integrator")
func replayIsDeterministic() {
  let inputs = [0.1, 0.2, 0.3]
  let first = inputs.reduce(0) { step($0, velocity: $1, dt: 0.5) }
  let second = inputs.reduce(0) { step($0, velocity: $1, dt: 0.5) }
  #expect(first == second)
}
