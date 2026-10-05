# Replace the posts screen with a CoinGecko price tracker

## Requirements

- req-watchlist: Launching the app shows Bitcoin, Ethereum and Solana, each with its name, its USD price and its 24-hour change as a percentage, green when up and red when down
- req-load-states: The first load shows a spinner, and a failed load shows a message with "Try again" that loads again and recovers once the network is back
- req-refresh: Pull to refresh reloads the prices, and the screen shows when the prices were last updated, which a successful refresh moves forward
- req-detail: Tapping an asset opens a detail screen with its current price and a line chart of the last 7 days
- req-chart-states: The chart has its own loading and error states, so a failed chart request still shows the price
- req-chart-cancel: Leaving the detail screen cancels its chart request if it is still running
- req-client: The CoinGecko client decodes recorded JSON responses for prices and the 7-day chart, and maps transport failures to typed errors, in tests that never touch the network
- req-existing-tests: The existing APIClient, LogClient and AppCore tests keep passing

## Areas

- APIClient (warm test unknown)
- AppFeature (warm test 31.7 s, build-only)
- InterviewStarter (xcode, warm test 76.8 s, build-only)
- LogClient is untouched; only `final` runs it.

## Assumptions

- "Replace that screen with the tracker" plus "keep the existing tests passing": the app's root scene switches to the new `WatchlistView`, while the posts `AppFeature`/`AppView` and `fetchPosts` stay in place so their unit tests keep passing unchanged. Only `LaunchFlowUITests`, which asserts the replaced screen's text, is rewritten to assert the tracker's launch outcome.
- Prices are modelled as `Double` USD values and formatted with the user's locale currency style fixed to USD; the 24-hour change is shown with 2 decimals and a sign.
- A pull to refresh keeps the current prices on screen and does not show the first-load spinner; a failed refresh with prices already shown keeps them and shows the error message with "Try again".
- "Last updated" is the time of the last successful price response, read from the `date` dependency so tests control it.
- The chart's own retry button lives on the detail screen; the detail screen's price comes from the watchlist's quote passed in when it opens.
- Leaving the detail screen dismisses the presented child; TCA cancels its effects on dismissal, and a unit test proves the chart request is cancelled.
- No explorers ran: the repository has 29 files and was read in full by the orchestrator.
- The network-off journeys can't run as flows, since the simulator can't cut its host's network mid-flow; unit tests with recorded JSON prove them.
- At the cutoff, app-core's merge gate had not finished: its prove step (tests run against the reverted source) hung for 17 minutes in AppFeaturePackageTests. Since no GREEN gate arrived, it was treated as a RED merge gate at the cutoff: the merge was undone and the task abandoned. Its branch spec/app-core keeps the work.

## Validation

| Done when | Layer | Check | Runs after | Writer | Reason |
|---|---|---|---|---|---|
| req-watchlist | flow | `qa/watchlist.flow.json` | launch-wiring | spec-validation | |
| req-detail | flow | `qa/detail.flow.json` | launch-wiring | spec-validation | |
| req-load-states | | | | | network: the simulator can't take its host's network down and bring it back mid-flow; WatchlistFeature unit tests prove the spinner, error and retry |
| req-refresh | | | | | WatchlistFeature unit tests with a controlled date prove refresh and last updated |
| req-chart-states | | | | | network: a flow can't make only the chart request fail; AssetDetailFeature unit tests prove it |
| req-chart-cancel | | | | | system: cancellation isn't visible in the running app; an AssetDetail/Watchlist unit test proves the effect is cancelled on dismiss |
| req-client | | | | | APIClientLive unit tests over recorded fixtures prove it |
| req-existing-tests | | | | | the final gate runs every area's existing tests |

### spec-contract
Declare the tracker's models, client endpoints, reducers' state and actions, and stub views, with no behaviour.
- Deps: none · Gate: slice · estLines: 220
- Why: every requirement crosses APIClient, AppCore and AppUI, so all tasks build against 1 declared shape.
- Scope:
  - `Asset` (with `Asset.watchlist`), `Quote`, `PricePoint`, `APIClient.fetchQuotes`/`fetchChart` with preview values
  - `WatchlistFeature` and `AssetDetailFeature` state and actions with no-op reducers
  - stub `WatchlistView`, `AssetDetailView` and the `TrackerID` accessibility identifiers
- Acceptance:
  - every touched area builds; slice is GREEN
- Out of scope:
  - any behaviour
- Covers: req-existing-tests
- Writes: Packages/APIClient/Sources/APIClient/APIClient.swift, Packages/APIClient/Sources/APIClientLive/APIClientLive.swift, Packages/AppFeature/Sources/AppCore/WatchlistFeature.swift, Packages/AppFeature/Sources/AppCore/AssetDetailFeature.swift, Packages/AppFeature/Sources/AppUI/WatchlistView.swift, Packages/AppFeature/Sources/AppUI/AssetDetailView.swift, Packages/AppFeature/Sources/AppUI/TrackerID.swift

### client-live
Implement the CoinGecko endpoints in the live client, tested over recorded JSON.
- Deps: spec-contract · Gate: slice · estLines: 180
- Why: req-client, "the client ... unit tests using recorded JSON responses, with no network".
- Scope:
  - `fetchQuotes(ids)` calls `https://api.coingecko.com/api/v3/simple/price?ids=<comma ids>&vs_currencies=usd&include_24hr_change=true` and maps `{id: {usd, usd_24h_change}}` to `[Quote]` in the order of `ids`
  - `fetchChart(id)` calls `https://api.coingecko.com/api/v3/coins/<id>/market_chart?vs_currency=usd&days=7` and maps `prices` `[[ms, price]]` to `[PricePoint]`
  - both reuse the existing `send` path, so offline, bad status and undecodable map to `APIError`; an id missing from the price response is `undecodable`
  - recorded fixtures `simple-price.json` and `market-chart.json` under `Tests/APIClientLiveTests/Fixtures/`
- Acceptance:
  - new tests in `CoinGeckoLiveTests.swift` fail first, then pass: decode both fixtures, request URLs, bad status, offline, malformed body; existing `APIClientLiveTests` stay green; slice is GREEN
- Out of scope:
  - caching, other currencies, the posts endpoint
- Covers: req-client
- Writes: Packages/APIClient/Sources/APIClientLive/APIClientLive.swift, Packages/APIClient/Tests/APIClientLiveTests/CoinGeckoLiveTests.swift, Packages/APIClient/Tests/APIClientLiveTests/Fixtures/simple-price.json, Packages/APIClient/Tests/APIClientLiveTests/Fixtures/market-chart.json
- Tests: Packages/APIClient/Tests/APIClientLiveTests/CoinGeckoLiveTests.swift

### app-core
Implement the watchlist and detail reducers: loading, refresh, last updated, retry, navigation and the chart's own states with cancellation.
- Deps: spec-contract · Gate: slice · estLines: 260
- Why: req-load-states, req-refresh, req-chart-states and req-chart-cancel are view logic the spec asks to unit test.
- Scope:
  - `WatchlistFeature`: `.task` loads quotes for `Asset.watchlist` ids with status `.loading` only when no quotes are shown; success stores quotes and `lastUpdated = date.now` and status `.loaded`; failure sets `.failed(error)` keeping old quotes and logs through `logClient`; `.retryButtonTapped` loads again; `.refresh` reloads without the first-load spinner; `.assetTapped(id)` presents `AssetDetailFeature.State(asset:quote:)`; `.ifLet(\.$detail)` composes the child
  - `AssetDetailFeature`: `.task` sets chart `.loading` and fetches the chart with a cancel id; success `.loaded(points)`, failure `.failed(error)`; `.retryChartButtonTapped` loads again; the quote stays in state whatever the chart does
- Acceptance:
  - new tests in `WatchlistFeatureTests.swift` and `AssetDetailFeatureTests.swift` fail first, then pass, using TestStore with stubbed `apiClient` and fixed `date`: first load, failure + retry recovery, refresh updates `lastUpdated`, failed refresh keeps quotes, tap presents detail, chart success, chart failure keeps the quote, dismissing the detail while the chart request is suspended cancels it (the stub observes `CancellationError`/`Task.isCancelled`); existing `AppFeatureTests` stay green; slice is GREEN
- Out of scope:
  - views, the live client, the posts `AppFeature`
- Covers: req-load-states, req-refresh, req-chart-states, req-chart-cancel
- Writes: Packages/AppFeature/Sources/AppCore/WatchlistFeature.swift, Packages/AppFeature/Sources/AppCore/AssetDetailFeature.swift, Packages/AppFeature/Tests/AppCoreTests/WatchlistFeatureTests.swift, Packages/AppFeature/Tests/AppCoreTests/AssetDetailFeatureTests.swift
- Tests: Packages/AppFeature/Tests/AppCoreTests/WatchlistFeatureTests.swift, Packages/AppFeature/Tests/AppCoreTests/AssetDetailFeatureTests.swift

### tracker-ui
Build the watchlist and detail SwiftUI screens over the contract's state, with the contract's accessibility identifiers.
- Deps: spec-contract · Gate: slice · estLines: 220
- Why: req-watchlist and req-detail, the screens the user sees.
- Scope:
  - `WatchlistView`: `NavigationStack` titled "Prices"; a `List` of `Asset.watchlist` rows with name, USD price and signed 24h change (green up, red down) using `TrackerID.row/price/change(id)`; `ProgressView` (`TrackerID.loading`) while status is `.loading` with no quotes; error text (`TrackerID.error`) with a "Try again" button (`TrackerID.retry`) on `.failed`; "Last updated <time>" text (`TrackerID.lastUpdated`) when `lastUpdated` is set; `.refreshable { await store.send(.refresh).finish() }`; `.task { await store.send(.task).finish() }`; tapping a row sends `.assetTapped(id)`; `.navigationDestination(item: $store.scope(state: \.detail, action: \.detail))` shows `AssetDetailView`
  - `AssetDetailView`: price text (`TrackerID.detailPrice`) always shown from the quote; a Swift Charts `LineMark` chart (`TrackerID.chart`) on `.loaded`, `ProgressView` (`TrackerID.chartLoading`) on `.loading`, error text (`TrackerID.chartError`) with a retry button (`TrackerID.chartRetry`) on `.failed`; `.task { await store.send(.task).finish() }`
  - previews with the preview client
- Acceptance:
  - the InterviewStarter app and AppFeature build; slice is GREEN
- Out of scope:
  - reducer logic, the app's root scene, UI tests
- Covers: req-watchlist, req-detail
- Writes: Packages/AppFeature/Sources/AppUI/WatchlistView.swift, Packages/AppFeature/Sources/AppUI/AssetDetailView.swift

### launch-wiring
Point the app's root scene at the tracker and rewrite the launch UI test for it.
- Deps: tracker-ui, app-core, client-live · Gate: slice · estLines: 50
- Why: "Replace that screen with the tracker"; req-watchlist on launch.
- Scope:
  - `InterviewStarterApp` builds a `Store(initialState: WatchlistFeature.State()) { WatchlistFeature() }` and shows `WatchlistView`
  - `LaunchFlowUITests` waits up to 20 s for either the `TrackerID.row("bitcoin")` element or the `TrackerID.error` text, so it passes with or without the network, and asserts that "Bitcoin", "Ethereum" and "Solana" rows exist when the load succeeds
- Acceptance:
  - the app builds for testing; slice is GREEN
- Out of scope:
  - deleting the posts `AppFeature`
- Covers: req-watchlist
- Writes: App/InterviewStarterApp.swift, UITests/LaunchFlowUITests.swift
- Tests: UITests/LaunchFlowUITests.swift

### spec-validation
Write the flow checks against the contract's names, and record why each fails now.
- Deps: spec-contract · Gate: slice · estLines: 80
- Why: req-watchlist and req-detail need checks that fail before their tasks merge and pass after.
- Scope:
  - `watchlist.flow.json` and `detail.flow.json` under `.harness/qa/spec/`
- Acceptance:
  - `qa lint` is GREEN on each flow; `qa run --at-base` reads each row red
- Out of scope:
  - source, tests in the tracked tree, and any commit
- Covers: req-watchlist, req-detail
- Writes: .harness/qa/spec/
