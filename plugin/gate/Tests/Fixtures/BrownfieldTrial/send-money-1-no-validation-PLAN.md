# Send money: pick a contact, enter an amount, confirm and send

## Requirements

- req-account-fake: The account sits behind an AccountClient interface whose in-memory fake starts at a $250.00 balance, lists 8 contacts, and has a send call that can be made to fail
- req-contact-search: Typing in the contact list's search field filters the contacts by name
- req-contact-select: Tapping a contact moves to the amount screen for that contact
- req-keypad-decimals: The keypad rejects a third digit after the decimal point and a second decimal point
- req-keypad-leading-zeros: The keypad never keeps a leading zero ("007" shows as "7") and delete removes the last typed character
- req-amount-format: The amount shows formatted as US-dollar currency as the user types
- req-continue-rule: Continue is enabled only for an amount above $0.00 and no more than the current balance
- req-decimal-money: Every money value is a Decimal, never a floating-point type
- req-confirm-send: The confirmation screen shows the contact and the amount, and Send calls the account client
- req-send-success: A successful send lowers the balance by the amount and puts the payment at the top of the first screen's activity list
- req-send-failure: A failed send leaves the balance unchanged and shows an error with a way to try again
- req-replace-screen: The posts screen is replaced by the send-money home screen, and the existing APIClient and LogClient tests still pass

## Areas

- TimedBuildStarter (warm test 34.1 s, build-only): the one xcode area; its packages AppFeature and the new AccountClient hold every change. The contract added AppCoreTests and AccountClientTests to the scheme's test action, so `test` runs the unit tests too.

## Assumptions

- "Replace that screen" and "keep the existing tests passing" conflict for the posts screen's own tests: the posts tests in AppFeatureTests and the launch UI test describe the removed screen, so they are rewritten for the new home screen; the APIClient and LogClient package tests stay untouched and must still pass.
- The APIClient package and its live module stay in the repository, unused by the new flow, since removing them is outside what the spec asks.
- The fake backend is the app's live value too (no real networking); a send fails when the app launches with `-account-fail-sends`, and tests make it fail through `AccountClient.inMemory(failSends: true)` or a stubbed `send`.
- "About 8 contacts" means exactly 8 fixed sample contacts with stable ids.
- The amount is entered in dollars with a "." decimal point and formatted as USD with the `en_US` locale, so tests are locale-independent.
- An empty amount shows as "$0.00"; typing "." first gives "0."; delete on an empty amount does nothing.
- Search matches a case-insensitive substring of the contact's name; an empty or whitespace-only query shows every contact.
- The home screen loads the balance from the client on appear, and after a send it updates the balance locally by subtracting the amount rather than reloading it.
- After a successful send the navigation stack pops back to the home screen, where the payment heads the activity list.
- Every requirement is proved by unit tests (TCA TestStore and plain Swift Testing) in the tasks that build it, so the validation table has reason-only rows and the plan has no validation task.
- The explorers were skipped: the repository has 1 area and is small enough to read in full.
- Halt (gate-red, amount-rules): the contract's scheme edit, which added AppCoreTests and AccountClientTests to the TimedBuildStarter test action, made the UI test runner fail to launch (SBMainWorkspace Busy). Chose the fixer (retry); it restored the scheme to the base, so the area's `test` runs only the UI tests and the package unit tests run through `swift test --package-path` alone, not through any gate.
- Halt (gate-red, root-flow): the rewritten launch UI test expects "$250.00" while the in-memory fake was still the contract stub; chose the fixer (retry), told to implement the account-fake task's fake and tests in its fix, since account-fake could not start before no-new-starts.
- Halt (gate-red, amount-confirm): 2 merge gates failed to launch the UI test runner (SBMainWorkspace Busy, then Mach error -308) while the root-flow fixer used the simulator; chose retry, undid the merge and launched no fixer, since a fixer's gate would compete for the same simulator before the cutoff.

### send-money-contract
Declare the account client, the amount input and the screen skeletons every task compiles against, with no behaviour.
- Deps: none · Gate: slice · estLines: 400
- Why: every requirement crosses AccountClient, AppCore and AppUI, so all tasks build against 1 declared shape.
- Scope:
  - the AccountClient package: Contact, Payment, AccountError, the AccountClient interface and a stubbed `inMemory` fake
  - AmountInput with stubbed rules; ContactsFeature, AmountFeature and ConfirmFeature with their State and Action and an empty body; stub views; AccessibilityID
  - AppCoreTests and AccountClientTests in the scheme's test action
- Acceptance:
  - the area builds; slice is GREEN
- Out of scope:
  - any behaviour
- Covers: req-decimal-money
- Writes: Packages/AccountClient/, Packages/AppFeature/Package.swift, Packages/AppFeature/Sources/AppUI/AccessibilityID.swift, .swiftgate.toml, TimedBuildStarter.xcodeproj/xcshareddata/xcschemes/TimedBuildStarter.xcscheme

### account-fake
Implement the in-memory account backend: $250.00, 8 contacts, and a send that can fail.
- Deps: send-money-contract · Gate: slice · estLines: 150
- Why: the spec's Setup: "a starting balance of $250.00, a list of about 8 contacts, and a send call that can be made to fail".
- Scope:
  - `Contact.samples`: 8 contacts with fixed UUIDs and distinct names
  - `AccountClient.inMemory(balance:contacts:failSends:)`: state held in a lock-isolated box shared by its closures; `send` throws `.sendFailed` when `failSends`, throws `.invalidAmount` for an amount not above 0 or above the balance, and otherwise lowers the balance and returns a Payment with a new UUID and the current date
- Acceptance:
  - AccountClientTests: the fake starts at 250, lists 8 contacts, a send of 40.25 leaves 209.75 and returns the payment, a failing send throws `.sendFailed` and leaves 250, an overdraw throws `.invalidAmount`; each fails against the stub first; slice is GREEN
- Out of scope:
  - the features and views
- Covers: req-account-fake, req-decimal-money
- Writes: Packages/AccountClient/Sources/, Packages/AccountClient/Tests/
- Does: run the package's tests with `swift test --package-path Packages/AccountClient` while iterating; the area's test command runs them at merge.

### amount-rules
Implement the keypad rules, the amount, its currency text and the Continue rule in AmountInput.
- Deps: send-money-contract · Gate: slice · estLines: 200
- Why: section 2 of the spec, "Enter an amount", and the acceptance criteria on the keypad and Continue.
- Scope:
  - `press`: digits append; a leading "0" is replaced by the next digit ("007" gives "7"); "." is rejected when one exists and gives "0." when first; a third digit after "." is rejected; delete removes the last character
  - `amount` as Decimal parsed without floating point (`Decimal(string:locale: en_US_POSIX)`), 0 when empty
  - `formatted` as USD currency with the en_US locale, such as "$1,234.50", "$0.00" when empty; while typing "12." show "$12.00" style text with 2 fraction digits
  - `canContinue(balance:)`: amount > 0 and amount <= balance
- Acceptance:
  - AmountInputTests (Swift Testing) for each rule above, including "007", a second ".", a third decimal digit, delete to empty, $0.00, exactly the balance and 1 cent above it; each fails against the stub first; slice is GREEN
- Out of scope:
  - the amount screen and its reducer
- Covers: req-keypad-decimals, req-keypad-leading-zeros, req-amount-format, req-continue-rule, req-decimal-money
- Writes: Packages/AppFeature/Sources/AppCore/AmountInput.swift, Packages/AppFeature/Tests/AppCoreTests/AmountInputTests.swift
- Does: run tests with `swift test --package-path Packages/AppFeature --filter AmountInputTests` while iterating.

### contacts
Build the searchable contact list: load contacts, filter by name, and report a tapped contact.
- Deps: send-money-contract · Gate: slice · estLines: 180
- Why: section 1 of the spec, "Pick a contact", and the acceptance criterion "searching the contact list filters it by name".
- Scope:
  - ContactsFeature: `.task` loads `accountClient.contacts()` into `contacts` (a failure leaves the list empty and logs nothing new); `.queryChanged` sets `query`; `filteredContacts` matches a case-insensitive substring of the name, all contacts for a blank query; `.contactTapped` sends `.delegate(.contactSelected)`
  - ContactsView: a List of `filteredContacts` with `.searchable` bound to `query`, each row a button with `AccessibilityID.contactRow` and the contact's name as its label; title "Send to"
- Acceptance:
  - ContactsFeatureTests (TCA TestStore): loading, filtering by a partial lowercase name, a blank query, and the delegate on tap; each fails against the stub first; slice is GREEN
- Out of scope:
  - navigation to the amount screen, which the root owns
- Covers: req-contact-search, req-contact-select
- Writes: Packages/AppFeature/Sources/AppCore/ContactsFeature.swift, Packages/AppFeature/Sources/AppUI/ContactsView.swift, Packages/AppFeature/Tests/AppCoreTests/ContactsFeatureTests.swift
- Does: run tests with `swift test --package-path Packages/AppFeature --filter ContactsFeatureTests` while iterating.

### amount-confirm
Build the amount screen with its custom keypad and the confirmation screen that sends the money.
- Deps: send-money-contract · Gate: slice · estLines: 320
- Why: sections 2 and 3 of the spec: the keypad screen, the Continue rule, and "Send calls the client" with its failure and retry.
- Scope:
  - AmountFeature: `.keyTapped` calls `state.input.press`; `.continueButtonTapped` sends `.delegate(.continued(contact:amount:))` only when `isContinueEnabled`
  - AmountView: the contact's name, `input.formatted` (`AccessibilityID.amountValue`), a 3-column keypad of 1-9, ".", 0 and delete (`amountKeyPrefix` + digit, `amountKeyDecimal`, `amountKeyDelete`), and a Continue button (`amountContinue`) disabled unless `isContinueEnabled`
  - ConfirmFeature: `.sendButtonTapped` and `.retryButtonTapped` clear `error`, set `isSending` and call `accountClient.send(amount, contact)`; success sends `.delegate(.sent(payment))`; an AccountError (or any other error, mapped to `.sendFailed`) sets `error` and clears `isSending`; a tap while sending does nothing
  - ConfirmView: the contact (`confirmContact`), the amount as USD currency (`confirmAmount`), a Send button (`confirmSend`) disabled while sending, and on error a message "Couldn't send the money" (`confirmError`) with a "Try again" button (`confirmRetry`)
- Acceptance:
  - AmountFeatureTests: keys reach the input, Continue is ignored at $0.00 and above the balance, and delegates at the balance
  - ConfirmFeatureTests: a send calls the client with the amount and contact and delegates the payment; a failed send shows the error; retry sends again; each fails against the stub first; slice is GREEN
- Out of scope:
  - AmountInput's rules (amount-rules), the balance update and navigation (root-flow)
- Covers: req-continue-rule, req-confirm-send, req-send-failure
- Writes: Packages/AppFeature/Sources/AppCore/AmountFeature.swift, Packages/AppFeature/Sources/AppCore/ConfirmFeature.swift, Packages/AppFeature/Sources/AppUI/AmountView.swift, Packages/AppFeature/Sources/AppUI/ConfirmView.swift, Packages/AppFeature/Tests/AppCoreTests/AmountFeatureTests.swift, Packages/AppFeature/Tests/AppCoreTests/ConfirmFeatureTests.swift
- Does: tests stub `AmountInput` through its public `init(text:)`, since amount-rules builds its rules in parallel; a ConfirmFeature test must not depend on AmountInput. Run tests with `swift test --package-path Packages/AppFeature --filter "AmountFeatureTests|ConfirmFeatureTests"`.

### root-flow
Replace the posts screen with the home screen: balance, activity list, and the send flow as a navigation stack.
- Deps: send-money-contract · Gate: slice · estLines: 300
- Why: requirement "on success, the balance drops by the amount, and the payment appears at the top of an activity list on the first screen", and the Setup's "replace that screen".
- Scope:
  - AppFeature: State holds `balance: Decimal?`, `activity: [Payment]` (newest first) and `path: StackState<Path.State>`, with `@Reducer enum Path { case contacts(ContactsFeature), amount(AmountFeature), confirm(ConfirmFeature) }`; `.task` loads the balance from `accountClient.balance()`; `.sendMoneyButtonTapped` pushes contacts; contacts' `.contactSelected` pushes amount with the current balance; amount's `.continued` pushes confirm; confirm's `.sent(payment)` lowers the balance by `payment.amount`, inserts the payment at index 0 of `activity` and empties `path`; remove the posts loading and its APIClient use
  - AppView: a NavigationStack over `path` showing the balance as USD currency (`homeBalance`), a "Send money" button (`homeSendButton`), and the activity list, each row (`homeActivityRow`) with the contact's name and the amount; the destinations use ContactsView, AmountView and ConfirmView
  - App/TimedBuildStarterApp.swift only if the root store's construction must change
  - rewrite AppFeatureTests for the new root, and LaunchFlowUITests so launch shows the balance "$250.00"
- Acceptance:
  - AppFeatureTests (TCA TestStore): the balance loads on appear; selecting a contact pushes the amount screen; continuing pushes confirm; a sent delegate lowers 250 by 40.25 to 209.75, puts the payment first ahead of an earlier one and pops to home; a failed send inside the stack leaves the balance at 250; each fails against the stub first; slice is GREEN
- Out of scope:
  - the child screens' own behaviour and views
- Covers: req-contact-select, req-send-success, req-send-failure, req-replace-screen
- Writes: Packages/AppFeature/Sources/AppCore/AppFeature.swift, Packages/AppFeature/Sources/AppUI/AppView.swift, Packages/AppFeature/Tests/AppCoreTests/AppFeatureTests.swift, App/TimedBuildStarterApp.swift, UITests/LaunchFlowUITests.swift
- Does: child reducers are empty in the contract, so drive the root tests by sending the children's delegate actions through `.path(.element(id:action:))`, with `accountClient` stubbed. Run tests with `swift test --package-path Packages/AppFeature --filter AppFeatureTests`.
