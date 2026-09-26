import GameEngine
import Testing

struct SeededGeneratorTests {
  @Test(
    "SplitMix64 matches the reference sequence — catches an RNG algorithm change that would invalidate recorded replays"
  )
  func referenceSequence() {
    var generator = SeededGenerator(seed: 0)
    #expect(generator.next() == 0xE220_A839_7B1D_CDAF)
    #expect(generator.next() == 0x6E78_9E6A_A1B9_65F4)
  }
}

struct GameEngineRulesTests {
  @Test("a human move is answered by one computer move — catches the computer skipping its turn")
  func computerAnswersHumanMove() {
    let state = GameEngine.step(GameState(seed: 1), .humanPlaced(4))
    #expect(state.board[4] == .x)
    #expect(state.board.filter { $0 == .o }.count == 1)
    #expect(state.outcome == .inProgress)
  }

  @Test("placing on an occupied cell is ignored — catches overwriting the opponent's mark")
  func occupiedCellIgnored() throws {
    let afterFirst = GameEngine.step(GameState(seed: 1), .humanPlaced(4))
    let index = try #require(afterFirst.board.firstIndex(of: .o))
    #expect(GameEngine.step(afterFirst, .humanPlaced(index)) == afterFirst)
    #expect(GameEngine.step(afterFirst, .humanPlaced(4)) == afterFirst)
  }

  @Test("out-of-range cells are ignored — catches an index-out-of-range crash on a bad tap")
  func outOfRangeIgnored() {
    let initial = GameState(seed: 1)
    #expect(GameEngine.step(initial, .humanPlaced(-1)) == initial)
    #expect(GameEngine.step(initial, .humanPlaced(9)) == initial)
  }

  @Test("each row, column and diagonal wins — catches a missing win line")
  func everyLineWins() {
    #expect(GameState.winningLines.count == 8)
    for line in GameState.winningLines {
      var board: [Player?] = Array(repeating: nil, count: 9)
      for cell in line { board[cell] = .o }
      #expect(GameState.outcome(of: board) == .won(.o), "line \(line)")
    }
  }

  @Test("a full board without a line is a draw — catches a finished game staying in progress")
  func fullBoardIsDraw() {
    let board: [Player?] = [.x, .o, .x, .x, .o, .o, .o, .x, .x]
    #expect(GameState.outcome(of: board) == .draw)
  }

  @Test("moves after the game ends are ignored — catches play continuing past a win")
  func noMovesAfterWin() {
    var finished = GameState(seed: 1)
    finished.board = [.x, .x, .x, .o, .o, nil, nil, nil, nil]
    finished.outcome = .won(.x)
    #expect(GameEngine.step(finished, .humanPlaced(8)) == finished)
  }

  @Test(
    "reset clears the board but keeps the RNG stream — catches reset replaying the same computer moves"
  )
  func resetKeepsRNG() {
    let played = GameEngine.step(GameState(seed: 1), .humanPlaced(4))
    let reset = GameEngine.step(played, .reset)
    #expect(reset.board == Array(repeating: nil, count: 9))
    #expect(reset.outcome == .inProgress)
    #expect(reset.rng == played.rng)
  }
}

struct GameEngineReplayTests {
  @Test("replay returns a board — catches replay crashing")
  func replayRuns() {
    #expect(GameEngine.replay(seed: 1, inputs: []).board.count == 9)
  }
}
