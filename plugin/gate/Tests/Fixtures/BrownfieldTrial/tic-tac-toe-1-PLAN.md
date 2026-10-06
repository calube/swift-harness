# Replace the posts screen with a tic-tac-toe game

## Requirements

- req-turns: X moves first and the turn alternates between X and O after each accepted move
- req-ignored-moves: A move on an occupied cell, or after the game has ended, changes nothing
- req-win-lines: Each of the 8 lines (3 rows, 3 columns, 2 diagonals) filled by one player ends the game with that player as the winner
- req-draw: A full board with no line ends the game as a draw
- req-rules-tested: The rules have unit tests that run without the UI
- req-board-screen: Launching the app shows an empty 3×3 board instead of the posts screen, and tapping an empty cell places the current player's mark
- req-status-text: The screen shows "X's turn" or "O's turn" while playing, and "X wins", "O wins" or "Draw" once the game ends
- req-new-game: A "New game" button clears the board and gives the turn back to X

## Areas

- TimedBuildStarter (xcode, root `.`; warm test time unknown: the warm-up recorded nothing, so slice builds only and tests run at merge)

## Assumptions

- The repository had both `.swiftgate.toml` and the run's discovered config, which blocked every gate; the plan branch's first commit (84e7d0b) deletes `.swiftgate.toml` so the brownfield profile is the only one. Revert that commit before merging the plan branch.
- The scheme's test action held only the UI test bundle, so the contract adds the `TicTacToeTests` and `AppCoreTests` package test targets to it; that is how "the rules have unit tests" and "keep the existing tests passing" are checked by the area's test command.
- The rules live in a new `TicTacToe` target inside the existing `AppFeature` package, not a new package, so the Xcode project and its `Package.resolved` stay unchanged.
- "Replace that screen" means the app's root shows the game; `AppFeature`, `AppView` and their tests stay in the package unchanged, so the existing reducer tests keep passing.
- The launch UI test checked the posts screen, which the spec removes; it is rewritten to check the game's launch state.
- A cell index outside 0...8 is ignored like an occupied cell.
- Accessibility names: cells `game.cell.0` to `game.cell.8` (row by row from the top left) with label "X", "O" or "Empty"; status text `game.status`; button `game.newGame` titled "New game".
- ttt-screen runs beside ttt-engine rather than after it, so both fit before the no-new-starts deadline; its UI flow test turns green only once ttt-engine merges.
- The stall watch uses 8 minutes, not the preset's 2: a slice gate measured 295 s here, and a worker's transcript doesn't move while its gate runs.
- The final `qa run` read 1 row red twice (runs 20261005T010144Z-9350394a, 20261005T010428Z-75c783e4): a different row each time, always with `exit 65: Failed to install or launch the test runner`, while the same `GameFlowUITests` class passed on the other 2 rows of each run. That is a simulator launch failure, not a code defect, so no fix task was added and the validation verdict stays RED as reported.
- The `final` and merge gates excuse the area's whole `test` step because it also fails at the base commit; no gate output says which test fails there.
- No explorers ran: 1 area, small enough to read directly.

## Validation

| Done when | Layer | Check | Runs after | Writer | Reason |
|---|---|---|---|---|---|
| req-turns | | | | | GameTests in ttt-engine check X first and alternation |
| req-ignored-moves | | | | | GameTests in ttt-engine check occupied cells and moves after the end |
| req-win-lines | | | | | GameTests in ttt-engine check all 8 lines for both players |
| req-draw | | | | | GameTests in ttt-engine check a full board with no line |
| req-rules-tested | | | | | TicTacToeTests import only TicTacToe, no UI module |
| req-board-screen | acceptance | `test: TimedBuildStarterUITests/GameFlowUITests` | ttt-screen | ttt-screen | |
| req-status-text | acceptance | `test: TimedBuildStarterUITests/GameFlowUITests` | ttt-screen | ttt-screen | |
| req-new-game | acceptance | `test: TimedBuildStarterUITests/GameFlowUITests` | ttt-screen | ttt-screen | |

### ttt-contract
Declare the TicTacToe engine types as stubs and run the package tests in the scheme.
- Deps: none · Gate: slice · estLines: 60
- Why: requirement "keep the rules separate from the UI"; both later tasks compile against `Game`.
- Scope:
  - `TicTacToe` target in `Packages/AppFeature` with `Player`, `GameStatus` and `Game` (`cells`, `status`, `play(at:)` as a no-op stub)
  - `TicTacToeTests` target, and `TicTacToeTests` plus `AppCoreTests` in the scheme's test action
- Acceptance:
  - the app builds; slice is GREEN
- Out of scope:
  - any rule behaviour
- Covers: req-rules-tested
- Writes: Packages/AppFeature/Package.swift, Packages/AppFeature/Sources/TicTacToe/, Packages/AppFeature/Tests/TicTacToeTests/, TimedBuildStarter.xcodeproj/xcshareddata/xcschemes/TimedBuildStarter.xcscheme, .swiftgate.toml

### ttt-engine
Implement the tic-tac-toe rules in `Game.play(at:)`, test-first.
- Deps: ttt-contract · Gate: slice · estLines: 140
- Why: spec section 1, "The game rules", and the criterion "The rules have unit tests that run without the UI".
- Scope:
  - `play(at:)` places the current player's mark, then sets `status` to `.won(player)` on a completed row, column or diagonal, `.draw` on a full board with no line, else `.turn(otherPlayer)`
  - a move on an occupied cell, an index outside 0...8, or any move once `status` is `.won` or `.draw` leaves the game unchanged
- Acceptance:
  - Swift Testing tests in `GameTests.swift` fail on the stub, then pass: X first and alternation; occupied cell ignored; all 8 lines win for X and for O (parameterised); no move accepted after a win; a full board with no line is `.draw`, including a last move that both fills the board and completes a line counting as a win
  - slice is GREEN
- Out of scope:
  - any UI, reducer or app change; changing the public API the contract declared
- Covers: req-turns, req-ignored-moves, req-win-lines, req-draw, req-rules-tested
- Writes: Packages/AppFeature/Sources/TicTacToe/, Packages/AppFeature/Tests/TicTacToeTests/
- Tests: Packages/AppFeature/Tests/TicTacToeTests/GameTests.swift

### ttt-screen
Make the app's root screen the tic-tac-toe board, driven by a TCA `GameFeature` over `Game`.
- Deps: ttt-contract · Gate: slice · estLines: 200
- Why: spec section 2, "The board screen", and the criteria on launch, tapping, the result text and "New game".
- Scope:
  - `GameFeature` reducer in `AppCore` (`Sources/AppCore/GameFeature.swift`): state holds a `Game`; actions `cellTapped(Int)` calls `game.play(at:)`, `newGameButtonTapped` resets to `Game()`
  - `GameView` in `AppUI` (`Sources/AppUI/GameView.swift`): a 3×3 grid of buttons with ids `game.cell.0`...`game.cell.8` and accessibility label "X", "O" or "Empty"; a `Text` with id `game.status` reading "X's turn", "O's turn", "X wins", "O wins" or "Draw"; a button titled "New game" with id `game.newGame`
  - `App/TimedBuildStarterApp.swift` roots the app on `GameFeature`/`GameView` instead of `AppFeature`/`AppView`
  - `UITests/LaunchFlowUITests.swift` checks launch shows "X's turn" and 9 empty cells, in place of the posts check
- Acceptance:
  - `GameFeatureTests` (Swift Testing, TestStore) in `Tests/AppCoreTests/` fail first, then pass: tapping a cell plays it, new game resets
  - `UITests/GameFlowUITests.swift`, class `GameFlowUITests`: launch shows "X's turn"; tapping alternates X and O and a tapped occupied cell keeps its mark; X completing the top row shows "X wins" and a later tap changes nothing; a drawn sequence shows "Draw"; "New game" empties the board and shows "X's turn"
  - slice is GREEN
- Out of scope:
  - removing `AppFeature`, `AppView`, `APIClient` or their tests; animations, iPad layout, a computer opponent
- Covers: req-board-screen, req-status-text, req-new-game
- Writes: Packages/AppFeature/Sources/AppCore/, Packages/AppFeature/Sources/AppUI/, Packages/AppFeature/Tests/AppCoreTests/, App/, UITests/
- Does: runs beside ttt-engine. `GameFeatureTests` state the expected game with `Game` itself (`$0.game.play(at: 4)`), never with hand-built cells, so they hold whatever the rules do. `GameFlowUITests` needs the rules and passes only once ttt-engine has merged; it runs at merge, since the area is build-only.
- Tests: Packages/AppFeature/Tests/AppCoreTests/GameFeatureTests.swift, UITests/GameFlowUITests.swift, UITests/LaunchFlowUITests.swift
