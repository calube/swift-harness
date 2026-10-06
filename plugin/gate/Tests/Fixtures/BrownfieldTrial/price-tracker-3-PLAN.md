# Replace the posts screen with a CoinGecko price tracker

## Requirements

- req-watchlist-rows: Launching the app shows Bitcoin, Ethereum and Solana, each with its name, its USD price and its 24-hour change as a percentage, green when up and red when down
- req-load-error-retry: The first load shows a spinner, a failed load shows "Couldn't load prices" with a "Try again" button, and "Try again" loads the prices once the network is back
- req-refresh-last-updated: The watchlist shows when the prices were last updated, and pull to refresh reloads the prices and updates that time
- req-detail-chart: Tapping an asset opens a detail screen with its current price and a line chart of its last 7 days of prices
- req-detail-chart-failure: A failed chart request shows the chart's own error with "Try again" while the detail screen still shows the price
- req-detail-cancel: Leaving the detail screen cancels its chart request if it is still running
- req-coingecko-client: The API client fetches quotes from CoinGecko's simple/price endpoint and 7-day prices from its market_chart endpoint, decodes recorded JSON responses and maps offline, bad-status and undecodable failures, with tests that never touch the network
- req-existing-tests: The repository's existing tests keep passing, rewritten only where they assert the posts screen this change removes

## Areas

- APIClient (warm test unknown; the warm-up recorded no events)
- AppFeature (warm test unknown)
- TimedBuildStarter (xcode, warm test unknown; its UI test moves to the fake client)

## Assumptions

- The repository is small, so the orchestrator read it whole and ran no explorers.
- "Keep the existing tests passing" can't hold literally for tests that assert the posts screen the spec replaces: `AppFeatureTests` and `LaunchFlowUITests` are rewritten for the watchlist, while `APIClient.fetchPosts` and its client tests stay untouched and keep passing.
- The client gains `fetchQuotes(ids:)` and `fetchChart(id:)` beside `fetchPosts`; the asset ids are CoinGecko's `bitcoin`, `ethereum` and `solana`, and the watchlist is a fixed list in `Asset.watchlist`.
- Prices format as en_US USD currency (`$64,000.00`) and the change as a signed percentage with 2 decimals (`+2.50%`), so flows can match fixed labels.
- "Last updated" shows `Updated <time with seconds>`, so a refresh a second later visibly changes it.
- A refresh that fails keeps the last prices on screen and shows the error message beside them; only a failed first load replaces the list.
- The UI tests and flows run against a fake `APIClient` picked by `-harness-scenario <name>` (`success`, `load-failure`, `detail-failure`), which the contract lands in `APIClient/Scenarios.swift`; with no argument the app runs live.
- Cancelling the chart request on leaving the detail screen is proved by a `TestStore` test with a suspended chart request; no simulator flow can observe a cancelled URL task.
- The refresh flow checks that the prices change after pull to refresh and that "Updated" stays shown; flows match fixed text only, so the changed "last updated" time is proved by `WatchlistFeatureTests`' refresh test.
- The before-merge flows of watchlist-screen read RED (gate-red halt); by rule the halt was answered retry and the merge fixer was sent the red rows.
- The detail screen opens by push navigation from the watchlist, using TCA presentation state (`@Presents var detail`) so dismissal cancels the child's effects.

### tracker-contract
Declare the CoinGecko client endpoints, models, fake scenarios, feature and view stubs every task compiles against.
- Deps: none · Gate: slice · estLines: 260
- Why: every requirement crosses the APIClient and AppFeature packages, so all tasks build against 1 declared shape.
- Scope:
  - `Asset`, `Quote`, `PricePoint`, `APIClient.fetchQuotes`, `APIClient.fetchChart`, live stubs, preview values
  - `APIClient.scenario(_:)` fakes and the `-harness-scenario` seam in the app's composition root
  - `WatchlistFeature`, `DetailFeature` state and actions with empty reducers; `WatchlistView`, `DetailView` stubs; `AccessibilityID`
- Acceptance:
  - every touched area builds; slice is GREEN
- Out of scope:
  - any behaviour change of the running app
- Covers: req-coingecko-client
- Writes: Packages/APIClient/Sources/APIClient/, Packages/APIClient/Sources/APIClientLive/APIClientLive.swift, Packages/AppFeature/Sources/AppCore/WatchlistFeature.swift, Packages/AppFeature/Sources/AppCore/DetailFeature.swift, Packages/AppFeature/Sources/AppUI/WatchlistView.swift, Packages/AppFeature/Sources/AppUI/DetailView.swift, Packages/AppFeature/Sources/AppUI/AccessibilityID.swift, App/TimedBuildStarterApp.swift

### coingecko-client
Implement the live CoinGecko quotes and market-chart requests in `APIClientLive`, tested against recorded JSON.
- Deps: tracker-contract · Gate: slice · estLines: 220
- Why: requirement req-coingecko-client, "the client ... have unit tests using recorded JSON responses, with no network".
- Scope:
  - `fetchQuotes(ids:)` requests `https://api.coingecko.com/api/v3/simple/price?ids=<ids joined by ,>&vs_currencies=usd&include_24hr_change=true` and decodes `{ "<id>": { "usd": Double, "usd_24h_change": Double } }` into `[Quote]` in the order of `ids`, skipping ids the response lacks
  - `fetchChart(id:)` requests `https://api.coingecko.com/api/v3/coins/<id>/market_chart?vs_currency=usd&days=7` and decodes `prices` `[[ms timestamp, price]]` into `[PricePoint]`
  - both reuse the existing `send(_:over:)` error mapping (offline, badStatus, undecodable)
  - recorded fixtures `Fixtures/simple-price.json` and `Fixtures/market-chart.json` captured in CoinGecko's shape
- Acceptance:
  - new tests in `CoinGeckoLiveTests.swift` for the request URLs, decoding both fixtures, a bad status, offline and a malformed body fail first against the contract stubs, then pass; the existing `APIClientLiveTests` keep passing; slice is GREEN
- Out of scope:
  - the client interface and models in `Sources/APIClient/`, which the contract fixed
- Covers: req-coingecko-client
- Writes: Packages/APIClient/Sources/APIClientLive/, Packages/APIClient/Tests/APIClientLiveTests/
- Tests: Packages/APIClient/Tests/APIClientLiveTests/CoinGeckoLiveTests.swift

### watchlist-screen
Replace the posts screen with the watchlist: rows, first-load spinner, error with retry, pull to refresh and last updated, presenting the detail screen.
- Deps: tracker-contract · Gate: slice · estLines: 320
- Why: spec section 1, "Watchlist", and the acceptance criteria on launch, refresh and "Try again".
- Scope:
  - `WatchlistFeature` reducer: `.task` loads quotes for `Asset.watchlist` once (status `.loading` with a spinner), `.refresh` reloads (awaitable for `.refreshable`), `.retryButtonTapped` reloads after a failure, success stores quotes and `lastUpdated` from `@Dependency(\.date)`, failure logs through `LogClient` and sets `.failed`; `.assetTapped(id)` sets `detail` to `DetailFeature.State(asset:quote:)`; `.ifLet(\.$detail, …)` composes `DetailFeature`
  - `AppFeature` becomes the root holding `watchlist: WatchlistFeature.State`; `AppView` shows `WatchlistView` in a `NavigationStack`
  - `WatchlistView`: a `List` with 1 row per asset (name, price, change in green or red), `ProgressView` on the first load, the error text and "Try again", `.refreshable`, "Updated <time>", and `navigationDestination(item:)` showing `DetailView`; every element uses the ids in `AccessibilityID`
  - rewrite `AppFeatureTests` for the root and add `WatchlistFeatureTests`; rewrite `LaunchFlowUITests` to launch with `-harness-scenario success` and expect the 3 rows
- Acceptance:
  - `WatchlistFeatureTests` for load, failure with log, retry, refresh updating `lastUpdated` and tapping an asset fail first against the contract stubs, then pass; slice is GREEN
- Out of scope:
  - the detail screen's body and chart, which detail-screen owns; the live client
- Covers: req-watchlist-rows, req-load-error-retry, req-refresh-last-updated, req-existing-tests
- Writes: Packages/AppFeature/Sources/AppCore/WatchlistFeature.swift, Packages/AppFeature/Sources/AppCore/AppFeature.swift, Packages/AppFeature/Sources/AppUI/WatchlistView.swift, Packages/AppFeature/Sources/AppUI/AppView.swift, Packages/AppFeature/Tests/AppCoreTests/AppFeatureTests.swift, Packages/AppFeature/Tests/AppCoreTests/WatchlistFeatureTests.swift, UITests/LaunchFlowUITests.swift
- Tests: Packages/AppFeature/Tests/AppCoreTests/WatchlistFeatureTests.swift, Packages/AppFeature/Tests/AppCoreTests/AppFeatureTests.swift, UITests/LaunchFlowUITests.swift
- Does: labels are fixed by the contract: error text "Couldn't load prices", button "Try again", last updated "Updated " + `date.formatted(date: .omitted, time: .standard)`; format prices with `Quote.formattedPrice` and changes with `Quote.formattedChange` from the contract.

### detail-screen
Build the detail screen: the current price and a 7-day line chart with its own loading and error states, cancelled on leaving.
- Deps: tracker-contract · Gate: slice · estLines: 260
- Why: spec section 2, "Detail", and the acceptance criteria on the chart, a failed chart and leaving the screen.
- Scope:
  - `DetailFeature` reducer: `.task` loads the chart with `fetchChart(id:)` under a cancel id, `.chartResponse` sets `.loaded` or `.failed`, `.retryChartButtonTapped` reloads; the price comes from state, so a chart failure never hides it
  - `DetailView`: the asset name and price, a Swift Charts `LineMark` chart, a `ProgressView` while the chart loads, and the chart error with "Try again"; `.task { await store.send(.task).finish() }`
  - `DetailFeatureTests`, including a test that dismissing the presented detail (through a parent `TestStore` over `WatchlistFeature` state with `detail` set, or `DetailFeature` with a suspended request and `store.send(.task)` then task cancellation) cancels a still-running chart request
- Acceptance:
  - `DetailFeatureTests` for chart load, chart failure keeping the price, retry and cancellation fail first against the contract stubs, then pass; slice is GREEN
- Out of scope:
  - the watchlist rows and navigation into the detail screen, which watchlist-screen owns
- Covers: req-detail-chart, req-detail-chart-failure, req-detail-cancel
- Writes: Packages/AppFeature/Sources/AppCore/DetailFeature.swift, Packages/AppFeature/Sources/AppUI/DetailView.swift, Packages/AppFeature/Tests/AppCoreTests/DetailFeatureTests.swift
- Tests: Packages/AppFeature/Tests/AppCoreTests/DetailFeatureTests.swift
- Does: labels are fixed by the contract: chart error text "Couldn't load the chart", button "Try again"; ids from `AccessibilityID`.

### spec-validation
Write the flow checks against the contract's names and fake scenarios, and record why each fails now.
- Deps: tracker-contract · Gate: slice · estLines: 120
- Why: every screen requirement needs a flow that fails before its tasks merge and passes after.
- Scope:
  - 1 file under `.harness/qa/spec/` per `## Validation` row whose `Writer` is this task
- Acceptance:
  - `qa lint` is GREEN on each flow; `qa run --at-base` reads each row red
- Out of scope:
  - source, tests in the tracked tree, and any commit
- Covers: req-watchlist-rows, req-load-error-retry, req-refresh-last-updated, req-detail-chart, req-detail-chart-failure
- Writes: .harness/qa/spec/

## Validation

| Done when | Layer | Check | Runs after | Writer | Reason |
|---|---|---|---|---|---|
| req-watchlist-rows | flow | `qa/watchlist.flow.json` | watchlist-screen | spec-validation | |
| req-load-error-retry | flow | `qa/watchlist-retry.flow.json` | watchlist-screen | spec-validation | |
| req-refresh-last-updated | flow | `qa/watchlist-refresh.flow.json` | watchlist-screen | spec-validation | |
| req-detail-chart | flow | `qa/detail-chart.flow.json` | watchlist-screen, detail-screen | spec-validation | |
| req-detail-chart-failure | flow | `qa/detail-chart-failure.flow.json` | watchlist-screen, detail-screen | spec-validation | |
| req-detail-cancel | | | | | system: the simulator exposes no view of an in-flight URL task being cancelled; DetailFeatureTests proves the cancellation |
| req-coingecko-client | | | | | the CoinGeckoLiveTests in coingecko-client decode recorded fixtures through a recording transport, with no network |
| req-existing-tests | | | | | gate: final runs every area's whole suite |
