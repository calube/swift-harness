# Replace the posts screen with a CoinGecko price tracker

## Requirements

- req-watchlist: Launching the app shows Bitcoin, Ethereum and Solana, each with its name, its USD price and its 24-hour change as a percentage, green when up and red when down, with a spinner during the first load
- req-refresh: Pull to refresh reloads the prices and updates the "last updated" time
- req-error-retry: When the price load fails the watchlist shows an error message with "Try again", and "Try again" recovers once the network is back
- req-detail-chart: Tapping an asset opens a detail screen with its current price and a line chart of the last 7 days
- req-chart-failure: The chart has its own loading and error states, and a failed chart request still shows the price
- req-detail-cancel: Leaving the detail screen cancels its chart request if it is still running
- req-client: The client decodes CoinGecko's simple/price and market_chart responses, tested with recorded JSON and no network
- req-existing-tests: The existing test suites keep passing

## Areas

- APIClient (swiftpm; warm test unknown, test_files narrows to changed tests)
- AppFeature (swiftpm; warm test unknown, test_files narrows to changed tests)
- InterviewStarter (xcode; composition root and UI tests; warm test 141.8 s, build-only)

## Assumptions

- "Replace that screen" retires the posts screen: AppFeature becomes the root that hosts the watchlist, and its posts-screen tests are rewritten for the watchlist. `APIClient.fetchPosts`, its live transport and its tests stay, so "keep the existing tests passing" holds for every test whose subject still exists.
- The watchlist is fixed in code as `Asset.watchlist` (bitcoin, ethereum, solana) and every price is fetched in 1 `simple/price` call.
- A zero 24-hour change counts as up (green).
- "Last updated" is the time of the last successful price load, shown with seconds so a refresh visibly changes it; a failed refresh keeps the previous prices and time and shows the error.
- Navigation to the detail screen is TCA presentation state (`@Presents`) on the watchlist; the detail's chart request runs from the view's `.task`, so leaving the screen cancels it.
- The chart uses Swift Charts (a system framework), so no package is added.
- Flows run against a fake APIClient picked by `-harness-scenario <name>` (success, load-failure, detail-failure), set from AppCore's `HarnessScenario` before the root store is built.
- Flow repair of req-watchlist, req-error-retry and req-detail-chart (cause flow-side: their `wait absent` steps never resolved though the fixer showed the element gone, after qa runs 20261005T094133Z-a656b868 and 20261005T094737Z-871120b2) was refused by `qa adopt --repair` as `qa.repair-weakens-check`, since swapping a `wait` for `is absent` drops a wait step.
- Halt on spec-watchlist after the refused repair (gate-red): took the recommended option, stop the build; spec-watchlist stays blocked with its fix branch spec/fix-spec-watchlist (slice GREEN at e500035) unmerged, and nothing new starts.

### spec-contract
Declare the CoinGecko client endpoints, the watchlist and detail features, their views' identifiers and the scenario seam, with behaviour unchanged.
- Deps: none · Gate: slice · estLines: 300
- Why: every requirement crosses the client, the features and the app root, so all tasks build against 1 declared shape.
- Scope:
  - `Asset`, `Quote`, `PricePoint` and `fetchQuotes`/`fetchChart` on `APIClient`, live stubs that throw
  - fake scenarios for flows, and the `-harness-scenario` seam in the app root
  - `WatchlistFeature`, `AssetDetailFeature` state and actions with empty reducers; stub views and `AccessibilityID`
- Acceptance:
  - every touched area builds; slice is GREEN
- Out of scope:
  - any behaviour of the new endpoints, reducers or views
- Covers: req-watchlist
- Writes: Packages/APIClient/Sources/APIClient/, Packages/AppFeature/Sources/AppCore/WatchlistFeature.swift, Packages/AppFeature/Sources/AppCore/AssetDetailFeature.swift, Packages/AppFeature/Sources/AppCore/HarnessScenario.swift, Packages/AppFeature/Sources/AppUI/WatchlistView.swift, Packages/AppFeature/Sources/AppUI/AssetDetailView.swift, Packages/AppFeature/Sources/AppUI/AccessibilityID.swift, App/InterviewStarterApp.swift

### spec-client-live
Implement the live CoinGecko endpoints and test them against recorded JSON.
- Deps: spec-contract · Gate: slice · estLines: 180
- Why: "The client and view logic have unit tests using recorded JSON responses, with no network."
- Scope:
  - `fetchQuotes` calls `GET https://api.coingecko.com/api/v3/simple/price?ids=…&vs_currencies=usd&include_24hr_change=true` and maps `usd` and `usd_24h_change` into `Quote`s in the order of the ids asked
  - `fetchChart` calls `GET https://api.coingecko.com/api/v3/coins/{id}/market_chart?vs_currency=usd&days=7` and maps `prices` `[ms, price]` pairs to `PricePoint`s
  - both reuse the existing `send` error mapping (offline, badStatus, undecodable); a missing id in the price response is undecodable
- Acceptance:
  - new tests in `APIClientLiveTests` with recorded `simple-price.json` and `market-chart.json` fixtures check the request URLs, the decoding, the status and offline errors; they fail first, then pass; slice is GREEN
- Out of scope:
  - the interface types (the contract landed them), the posts endpoint
- Covers: req-client
- Writes: Packages/APIClient/Sources/APIClientLive/, Packages/APIClient/Tests/APIClientLiveTests/
- Tests: Packages/APIClient/Tests/APIClientLiveTests/CoinGeckoLiveTests.swift

### spec-watchlist
Build the watchlist feature and screen, and make it the app's root in place of the posts screen.
- Deps: spec-contract · Gate: slice · estLines: 350
- Why: spec section 1, and acceptance criteria 1 to 3.
- Scope:
  - `WatchlistFeature`: `.task` loads quotes once with a spinner, `.refreshPulled` reloads, `.retryButtonTapped` reloads after a failure, `lastUpdated` from `@Dependency(\.date)`, errors logged; `.assetTapped` presents `AssetDetailFeature` with the asset and its quote; `.ifLet` the detail
  - view logic for formatting: USD price text, signed percent text and up/down direction
  - `WatchlistView`: rows with name, price, change (green up, red down), `ProgressView` on first load, `.refreshable`, error text with a "Try again" button, "Last updated" text, navigation to `AssetDetailView`, every `AccessibilityID` the contract declares
  - `AppFeature`/`AppView` host the watchlist; posts-screen tests rewritten; `LaunchFlowUITests` launches with `-harness-scenario success` and waits for the 3 rows
- Acceptance:
  - `WatchlistFeatureTests` for first load, refresh updating `lastUpdated`, failure then retry, tap presenting detail, and the formatting fail first, then pass; slice is GREEN
- Out of scope:
  - the detail screen's own behaviour and the live client
- Covers: req-watchlist, req-refresh, req-error-retry, req-existing-tests
- Writes: Packages/AppFeature/Sources/AppCore/WatchlistFeature.swift, Packages/AppFeature/Sources/AppCore/AppFeature.swift, Packages/AppFeature/Sources/AppUI/WatchlistView.swift, Packages/AppFeature/Sources/AppUI/AppView.swift, Packages/AppFeature/Tests/AppCoreTests/WatchlistFeatureTests.swift, Packages/AppFeature/Tests/AppCoreTests/AppFeatureTests.swift, UITests/LaunchFlowUITests.swift
- Tests: Packages/AppFeature/Tests/AppCoreTests/WatchlistFeatureTests.swift, Packages/AppFeature/Tests/AppCoreTests/AppFeatureTests.swift

### spec-detail
Build the asset detail feature and screen with its 7-day chart.
- Deps: spec-contract · Gate: slice · estLines: 250
- Why: spec section 2, and acceptance criteria 4 and 5.
- Scope:
  - `AssetDetailFeature`: `.task` sets the chart loading and fetches `fetchChart(asset.id)`; success shows points, failure shows the chart error while the price stays; `.retryChartButtonTapped` reloads the chart
  - `AssetDetailView`: price text, a Swift Charts `LineMark` chart, its own spinner and error with retry, `.task { await store.send(.task).finish() }` so leaving cancels the request
- Acceptance:
  - `AssetDetailFeatureTests` for chart success, chart failure keeping the price, retry, and cancelling the `.task` send cancelling the in-flight request fail first, then pass; slice is GREEN
- Out of scope:
  - the watchlist and the navigation into the screen
- Covers: req-detail-chart, req-chart-failure, req-detail-cancel
- Writes: Packages/AppFeature/Sources/AppCore/AssetDetailFeature.swift, Packages/AppFeature/Sources/AppUI/AssetDetailView.swift, Packages/AppFeature/Tests/AppCoreTests/AssetDetailFeatureTests.swift
- Tests: Packages/AppFeature/Tests/AppCoreTests/AssetDetailFeatureTests.swift

### spec-validation
Write the flow checks against the contract's names and scenarios, and record why each fails now.
- Deps: spec-contract · Gate: slice · estLines: 120
- Why: every screen requirement needs a check that fails before its tasks merge and passes after.
- Scope:
  - 1 file under `.harness/qa/spec/` per `## Validation` row whose `Writer` is this task
- Acceptance:
  - `qa lint` is GREEN on each flow; `qa run --at-base` reads each row red
- Out of scope:
  - source, tests in the tracked tree, and any commit
- Covers: req-watchlist, req-refresh, req-error-retry, req-detail-chart, req-chart-failure
- Writes: .harness/qa/spec/

## Validation

| Done when | Layer | Check | Runs after | Writer | Reason |
|---|---|---|---|---|---|
| req-watchlist | flow | `qa/watchlist-launch.flow.json` | spec-watchlist | spec-validation | |
| req-refresh | flow | `qa/watchlist-refresh.flow.json` | spec-watchlist | spec-validation | |
| req-error-retry | flow | `qa/watchlist-retry.flow.json` | spec-watchlist | spec-validation | |
| req-detail-chart | flow | `qa/detail-chart.flow.json` | spec-watchlist, spec-detail | spec-validation | |
| req-chart-failure | flow | `qa/detail-chart-failure.flow.json` | spec-watchlist, spec-detail | spec-validation | |
| req-detail-cancel | | | | | system: the simulator UI can't observe whether an in-flight chart request was cancelled; AssetDetailFeatureTests checks it |
| req-client | | | | | the recorded-JSON tests in spec-client-live prove decoding and errors with no network |
| req-existing-tests | | | | | gate: final runs every area's whole suite |
