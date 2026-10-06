# Timed-build starter

A small SwiftUI app for timed rehearsals of `/swift-harness:ship`. It stands in for a project at the
start of a timed build: already built, already green, so the clock goes to features and
not to setup.

It is not an eval suite app. It has no hidden tests and no graded tasks.

## What's in it

- `App/`: the thin app target and composition root.
- `Packages/AppFeature`: `AppCore` holds the root `AppFeature` reducer, and `AppUI` holds its view.
  The root screen loads posts and shows how many arrived.
- `Packages/APIClient`: `APIClient` fetches posts from
  [JSONPlaceholder](https://jsonplaceholder.typicode.com), and `APIClientLive` does the request.
  Errors map to `APIError` (`offline`, `badStatus`, `undecodable`).
- `Packages/LogClient`: `LogClient` and its OSLog backend in `LogClientLive`.
- `UITests/`: 1 launch flow, declared in `.swiftgate.toml`.
- `specs/`: 3 practice READMEs of rising size, each written as a self-contained brief.

Every package pins TCA 1.26.2 and its dependencies to the same versions as `examples/SampleApp`.

## Warm it before a run

A cold build of TCA and its macros takes minutes. Pay that cost before the timer starts.

1. Copy this directory into a fresh git repository with an `origin/main`, since the push tier
   diffs against it. Commit and push the untouched starter.
2. Open `TimedBuildStarter.xcodeproj` in Xcode 26.2 once, let it resolve packages, and build the
   `TimedBuildStarter` scheme for an iPhone 17 simulator on iOS 26.2.
3. From the starter's root, run `swiftgate check --tier push`. It should end GREEN. The second run
   is the warm one, and takes well under a minute.
4. Run `swiftgate test --tier t3` once to build the app for the simulator and run the launch flow.

Then copy in any assets the brief ships with, and start the run:

```sh
/swift-harness:ship specs/1-list-detail.md --preset timed
```

## Practice specs

| Spec | Adds | Parts a planner can split |
|---|---|---|
| `specs/1-list-detail.md` | a posts list and a detail screen with author and comments | list, detail |
| `specs/2-favorites-search.md` | favorites stored on the device, and search over the list | list and detail, favorites, search |
| `specs/3-offline-sync.md` | a saved list, a compose form, and an offline queue that syncs | offline list, compose, queue, sync |
