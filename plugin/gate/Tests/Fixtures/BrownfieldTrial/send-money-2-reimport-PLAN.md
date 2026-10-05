# Send money: replace the posts screen with a contact, amount and confirm flow

## Requirements

- req-fake: The account sits behind an AccountClient interface whose in-memory fake starts at $250.00 with 8 contacts, and whose send can be made to fail
- req-search: Typing in the contact search filters the contact list by name, ignoring case
- req-pick-contact: Tapping a contact opens the amount screen for that contact
- req-keypad: The keypad enters digits, a decimal point and delete, rejects a third decimal digit and a second decimal point, and drops leading zeros ("007" reads "7")
- req-amount-format: The amount shows formatted as US dollar currency as the user types
- req-continue: "Continue" is enabled only for an amount above $0.00 and no more than the current balance
- req-decimal: Money is held as Decimal, never a floating-point type
- req-confirm: The confirmation screen shows the contact and the amount, and "Send" calls the account client
- req-send-success: A successful send lowers the balance by the amount and puts the payment at the top of the first screen's activity list
- req-send-failure: A failed send leaves the balance unchanged and shows an error with a way to try again

## Areas

- AppFeature (swiftpm, Packages/AppFeature): every source and unit test of the change; warm test time unknown, slice measures it
- InterviewStarter (xcode, root `.`): the app target and UITests; build-only, since no warm-up measured its tests

## Assumptions

- The repository is small, so the orchestrator read it whole and launched no explorers.
- "Replace that screen" removes the posts loading from the root feature and its view; the contract commit owns that removal, together with the posts tests in AppFeatureTests, since their behaviour no longer exists. "Keep the existing tests passing" then covers the APIClient and LogClient suites, which stay untouched, and the launch UI test, rewritten to check the new first screen.
- The APIClient package stays as it is; the app no longer calls it.
- The account client lives in a new `AccountClient` library target inside the AppFeature package rather than a new package, so it stays inside an area the gates already run and needs no Xcode project change.
- The in-memory fake is the client's live value, since no real backend exists; the app launched with the `-failSends` argument gets a fake whose sends fail, which is how a flow checks the failure path.
- The fake keeps its own balance and lowers it on a successful send; a send above its balance throws `insufficientFunds`; the root feature lowers its shown balance by the payment's amount on success.
- Search matches a case-insensitive substring of the contact's name; an empty search shows every contact.
- The amount entry caps nothing beyond the spec's rules: the balance limit gates "Continue", not the keypad.
- Delete on an empty amount does nothing; a decimal point first reads "0." and shows "$0.00".
- After a successful send the navigation pops back to the first screen, where the new payment heads the activity list.
- "A way to try again" is a "Try again" button on the confirmation screen that sends the same payment again.
- The 3 running tasks all appear in a validation row's Runs after, so none may merge before the at-base qa run, and build next offered no slot for spec-validation while they held all 3: spec-validation started outside build next, with worktree create and ledger set, to break that wait.
- Currency formatting uses US dollars with 2 fraction digits ("$12.50"), as the spec's amounts do.

### send-money-contract
Declare the account client, the feature states and actions, the accessibility ids and stub screens every task compiles against.
- Deps: none · Gate: slice · estLines: 420
- Why: every requirement crosses AccountClient, AppCore and AppUI, so each task builds against 1 declared shape.
- Scope:
  - the AccountClient target with Contact, Payment, SendError, the client and its seed contacts
  - AmountInput, KeypadKey, AmountFeature, ConfirmFeature and the root AppFeature with stub bodies
  - AccessibilityID, stub AppView, AmountView and ConfirmView; the posts screen removed
- Acceptance:
  - every touched area builds; slice is GREEN
- Out of scope:
  - any behaviour of the new types
- Covers: req-fake, req-decimal
- Writes: Packages/AppFeature/Package.swift, Packages/AppFeature/Sources/AccountClient/AccountClient.swift, Packages/AppFeature/Sources/AppCore/AccessibilityID.swift, UITests/LaunchFlowUITests.swift

### account-fake
Implement the in-memory AccountClient fake.
- Deps: send-money-contract · Gate: slice · estLines: 120
- Why: setup asks for "a client interface with an in-memory fake: a starting balance of $250.00, a list of about 8 contacts, and a send call that can be made to fail".
- Scope:
  - `AccountClient.inMemory(balance:contacts:failSends:)` keeps a locked balance; `send` lowers it and returns a Payment with a fresh id
  - with `failSends` set, `send` throws `SendError.declined` and leaves the balance; an amount above the balance throws `insufficientFunds`
- Acceptance:
  - InMemoryAccountTests for a successful send, a failing send, a send above the balance and the starting values fail first, then pass; slice is GREEN
- Out of scope:
  - the client interface and the seed contacts, which the contract landed
- Covers: req-fake
- Writes: Packages/AppFeature/Sources/AccountClient/InMemoryAccount.swift, Packages/AppFeature/Tests/AppCoreTests/InMemoryAccountTests.swift
- Tests: Packages/AppFeature/Tests/AppCoreTests/InMemoryAccountTests.swift

### amount-entry
Implement the amount-entry rules and the amount feature.
- Deps: send-money-contract · Gate: slice · estLines: 220
- Why: "Enter an amount": at most 2 decimal digits, no leading zeros, currency formatting, "Continue" only for $0.00 < amount <= balance, and Decimal for money.
- Scope:
  - `AmountInput.press`, `amount`, `formatted` and `canContinue(amount:balance:)`
  - `AmountFeature`: `keyTapped` updates the input; `continueButtonTapped` sends `delegate(.continued)` only when `State.canContinue`
- Acceptance:
  - AmountInputTests cover a third decimal digit, a second decimal point, "007" reading "7", delete, a leading decimal point and formatting; canContinue at $0.00, at the balance and 1 cent above it
  - AmountFeatureTests cover keys updating the input and continue being refused when disabled; slice is GREEN
- Out of scope:
  - the keypad view and navigation to the confirmation screen
- Covers: req-keypad, req-amount-format, req-continue, req-decimal
- Writes: Packages/AppFeature/Sources/AppCore/AmountInput.swift, Packages/AppFeature/Sources/AppCore/AmountFeature.swift, Packages/AppFeature/Tests/AppCoreTests/AmountInputTests.swift, Packages/AppFeature/Tests/AppCoreTests/AmountFeatureTests.swift
- Tests: Packages/AppFeature/Tests/AppCoreTests/AmountInputTests.swift, Packages/AppFeature/Tests/AppCoreTests/AmountFeatureTests.swift

### send-flow
Implement search, navigation, the confirm-and-send feature, and the balance and activity updates in the root feature.
- Deps: send-money-contract · Gate: slice · estLines: 260
- Why: requirements "Pick a contact" and "Confirm and send": search filters by name, a tap opens the amount screen, Send calls the client, success updates the balance and activity, failure leaves the balance and shows an error with retry.
- Scope:
  - `AppFeature.State.filteredContacts`; `task` loads balance and contacts from the client; `contactTapped` pushes `.amount`; the amount delegate pushes `.confirm`; the confirm `sent` delegate lowers the balance, inserts the payment at index 0 of `activity` and pops the path
  - `ConfirmFeature`: send and retry call `accountClient.send`, set `isSending`, keep `error` on failure and clear it on retry, and send `delegate(.sent)` on success; log a failed send through LogClient
- Acceptance:
  - AppFeatureTests and ConfirmFeatureTests with a stubbed AccountClient, for search, the tap, a success and a failure then retry, fail first, then pass; slice is GREEN
- Out of scope:
  - the views, the fake and the amount rules
- Covers: req-search, req-pick-contact, req-confirm, req-send-success, req-send-failure
- Writes: Packages/AppFeature/Sources/AppCore/AppFeature.swift, Packages/AppFeature/Sources/AppCore/ConfirmFeature.swift, Packages/AppFeature/Tests/AppCoreTests/AppFeatureTests.swift, Packages/AppFeature/Tests/AppCoreTests/ConfirmFeatureTests.swift
- Tests: Packages/AppFeature/Tests/AppCoreTests/AppFeatureTests.swift, Packages/AppFeature/Tests/AppCoreTests/ConfirmFeatureTests.swift

### send-ui
Build the home, amount and confirmation screens over the contract's stores.
- Deps: send-money-contract · Gate: slice · estLines: 260
- Why: the spec's 3 screens: a searchable contact list with the balance and activity, a custom keypad with Continue, and a confirmation screen with Send, the error and Try again.
- Scope:
  - AppView: the balance, the search field, contact rows as buttons sending `contactTapped`, and the activity list newest first
  - AmountView: the formatted amount, keys 0-9, decimal point and delete sending `keyTapped`, and Continue disabled unless `canContinue`
  - ConfirmView: contact, amount, Send, a progress state, and on error its message with a Try again button
  - every control carries its `AccessibilityID`
- Acceptance:
  - the app builds and LaunchFlowUITests compiles; slice is GREEN
- Out of scope:
  - reducer logic, the fake and the amount rules
- Covers: req-search, req-send-success, req-send-failure
- Writes: Packages/AppFeature/Sources/AppUI/
- Does: views read only the contract's state and actions and the AccessibilityID names; keep the launch UI test as the contract wrote it.

### spec-validation
Write the simulator flows against the contract's names, and record why each fails now.
- Deps: send-money-contract · Gate: slice · estLines: 80
- Why: each screen requirement needs a check that fails before its tasks merge and passes after.
- Scope:
  - 1 file under `.harness/qa/spec/` per `## Validation` row whose `Writer` is this task
- Acceptance:
  - `qa lint` is GREEN on each flow; `qa run --at-base` reads each row red
- Out of scope:
  - source, tests in the tracked tree, and any commit
- Covers: req-search, req-send-success, req-send-failure
- Writes: .harness/qa/spec/

## Validation

| Done when | Layer | Check | Runs after | Writer | Reason |
|---|---|---|---|---|---|
| req-fake | | | | | the InMemoryAccountTests in account-fake check the starting balance, the contacts and a failing send |
| req-search | flow | `qa/search-contacts.flow.json` | send-flow, send-ui | spec-validation | |
| req-pick-contact | | | | | the AppFeatureTests in send-flow check a tap pushes the amount screen; the send flows drive it in the app |
| req-keypad | | | | | the AmountInputTests in amount-entry check each keypad rule; the send flows drive the keypad in the app |
| req-amount-format | | | | | the AmountInputTests in amount-entry check the formatting |
| req-continue | | | | | the AmountInputTests in amount-entry check the bounds |
| req-decimal | | | | | the types declare Decimal; the AmountInputTests check exact cent arithmetic |
| req-confirm | | | | | the ConfirmFeatureTests in send-flow check Send calls the client; the send flows pass through the confirmation screen |
| req-send-success | flow | `qa/send-success.flow.json` | account-fake, amount-entry, send-flow, send-ui | spec-validation | |
| req-send-failure | flow | `qa/send-failure.flow.json` | account-fake, amount-entry, send-flow, send-ui | spec-validation | |
