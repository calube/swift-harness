public enum Player: Sendable, Equatable { case x, o }

public enum Outcome: Sendable, Equatable {
  case inProgress
  case won(Player)
  case draw
}

public enum GameInput: Sendable, Equatable {
  case humanPlaced(Int)
  case reset
}

/// SplitMix64. The algorithm is part of the replay contract: changing it changes every recorded game.
public struct SeededGenerator: RandomNumberGenerator, Sendable, Equatable {
  private var state: UInt64

  public init(seed: UInt64) {
    state = seed
  }

  public mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  /// Uniform-enough index in `0..<count`. Deliberately not `Int.random(in:using:)`, whose
  /// sampling algorithm the standard library does not promise to keep stable across releases.
  mutating func nextIndex(below count: Int) -> Int {
    Int(next() % UInt64(count))
  }
}

public struct GameState: Sendable, Equatable {
  public static let cellCount = 9
  public static let winningLines: [[Int]] = [
    [0, 1, 2], [3, 4, 5], [6, 7, 8],
    [0, 3, 6], [1, 4, 7], [2, 5, 8],
    [0, 4, 8], [2, 4, 6],
  ]

  public var board: [Player?]
  public var outcome: Outcome
  public var rng: SeededGenerator

  public init(seed: UInt64) {
    self.board = Array(repeating: nil, count: Self.cellCount)
    self.outcome = .inProgress
    self.rng = SeededGenerator(seed: seed)
  }

  public static func outcome(of board: [Player?]) -> Outcome {
    for line in winningLines {
      if let player = board[line[0]], board[line[1]] == player, board[line[2]] == player {
        return .won(player)
      }
    }
    return board.contains(nil) ? .inProgress : .draw
  }
}

/// Pure tic-tac-toe state machine: the human plays X, the computer answers with O on a
/// cell chosen by the state's seeded generator.
public enum GameEngine {
  public static func step(_ state: GameState, _ input: GameInput) -> GameState {
    var next = state
    switch input {
    case .reset:
      next.board = Array(repeating: nil, count: GameState.cellCount)
      next.outcome = .inProgress
    case .humanPlaced(let cell):
      guard next.outcome == .inProgress, next.board.indices.contains(cell), next.board[cell] == nil
      else { return state }
      next.board[cell] = .x
      next.outcome = GameState.outcome(of: next.board)
      guard next.outcome == .inProgress else { return next }
      let empty = next.board.indices.filter { next.board[$0] == nil }
      next.board[empty[next.rng.nextIndex(below: empty.count)]] = .o
      next.outcome = GameState.outcome(of: next.board)
    }
    return next
  }

  public static func replay(seed: UInt64, inputs: [GameInput]) -> GameState {
    inputs.reduce(GameState(seed: seed), step)
  }
}
