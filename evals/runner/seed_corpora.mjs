// Writes the rule corpora under evals/corpora/ from the seeds below, so every label is right by
// construction: a seed applies 1 edit to a clean SampleApp file or 1 markdown text and names the
// rule ids that edit should trip. Run: node evals/runner/seed_corpora.mjs
//
// A seed's `edit` must match its base text exactly once, or the generator stops: a seed that no
// longer applies would otherwise label a clean file as a violation.
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..')
const app = join(root, 'examples/SampleApp')
const corpora = join(root, 'evals/corpora')

const CORE = 'Packages/CounterFeature/Sources/CounterCore/CounterFeature.swift'
const CLIENT = 'Packages/APIClient/Sources/APIClient/APIClient.swift'
const LIVE = 'Packages/APIClient/Sources/APIClientLive/APIClientLive.swift'
const LOG_LIVE = 'Packages/LogClient/Sources/LogClientLive/LogClientLive.swift'
const UI = 'Packages/CounterFeature/Sources/CounterUI/CounterView.swift'
const APP = 'App/SampleApp.swift'
const ENGINE = 'Packages/GameEngine/Sources/GameEngine/GameEngine.swift'
const ENGINE_TESTS = 'Packages/GameEngine/Tests/GameEngineTests/GameEngineTests.swift'
const COUNTER_PKG = 'Packages/CounterFeature/Package.swift'
const API_PKG = 'Packages/APIClient/Package.swift'
const LOG_PKG = 'Packages/LogClient/Package.swift'
const CONFIG = '.swiftgate.toml'

const base = (path) => readFileSync(join(app, path), 'utf8')

function replaceOnce(text, from, to, where) {
  const count = text.split(from).length - 1
  if (count !== 1) throw new Error(`${where}: edit anchor matched ${count} times, expected 1:\n${from}`)
  return text.replace(from, () => to)
}

// Appends a function whose body is `body` to a Swift file.
const probe = (path, body) => ({ [path]: base(path) + `\nfunc seededProbe() async throws {\n  ${body}\n}\n` })
const replace = (path, from, to) => ({ [path]: replaceOnce(base(path), from, to, path) })
const prepend = (path, text) => ({ [path]: text + base(path) })

const coreDeps = `      name: "CounterCore",
      dependencies: [
`
const addCoreDep = (dep) => replace(COUNTER_PKG, coreDeps, coreDeps + `        ${dep},\n`)

const lint = [
  // D1: time, ids, waiting and randomness in Core or a client interface.
  ['date-init-core', 'positive', ['det.date-init'], probe(CORE, '_ = Date()'), 'D1'],
  ['date-now-core', 'positive', ['det.date-init'], probe(CORE, '_ = Date.now'), 'D1'],
  ['date-init-explicit-core', 'positive', ['det.date-init'], probe(CORE, '_ = Date.init()'), 'D1'],
  ['date-qualified-core', 'positive', ['det.date-init'], probe(CORE, '_ = Foundation.Date()'), 'D1'],
  ['date-since-now-core', 'positive', ['det.date-init'], probe(CORE, '_ = Date(timeIntervalSinceNow: 60)'), 'D1'],
  ['date-init-client', 'positive', ['det.date-init'], probe(CLIENT, '_ = Date()'), 'D1'],
  ['uuid-init-core', 'positive', ['det.uuid-init'], probe(CORE, '_ = UUID()'), 'D1'],
  ['uuid-string-core', 'positive', ['det.uuid-init'], probe(CORE, '_ = UUID().uuidString'), 'D1'],
  ['uuid-init-explicit-core', 'positive', ['det.uuid-init'], probe(CORE, '_ = UUID.init()'), 'D1'],
  ['uuid-init-client', 'positive', ['det.uuid-init'], probe(CLIENT, '_ = UUID()'), 'D1'],
  ['task-sleep-for-core', 'positive', ['det.task-sleep'], probe(CORE, 'try await Task.sleep(for: .seconds(1))'), 'D1'],
  ['task-sleep-nanoseconds-core', 'positive', ['det.task-sleep'], probe(CORE, 'try await Task.sleep(nanoseconds: 1_000)'), 'D1'],
  ['task-sleep-client', 'positive', ['det.task-sleep'], probe(CLIENT, 'try await Task.sleep(for: .seconds(1))'), 'D1'],
  ['async-after-main-core', 'positive', ['det.async-after'], probe(CORE, 'DispatchQueue.main.asyncAfter(deadline: .now() + 1) {}'), 'D1'],
  ['async-after-global-core', 'positive', ['det.async-after'], probe(CORE, 'DispatchQueue.global().asyncAfter(deadline: .now() + 1) {}'), 'D1'],
  ['random-in-core', 'positive', ['det.random'], probe(CORE, '_ = Int.random(in: 0..<6)'), 'D1'],
  ['random-bool-core', 'positive', ['det.random'], probe(CORE, '_ = Bool.random()'), 'D1'],
  ['random-element-core', 'positive', ['det.random'], probe(CORE, '_ = [1, 2, 3].randomElement()'), 'D1'],
  ['shuffled-core', 'positive', ['det.random'], probe(CORE, '_ = [1, 2, 3].shuffled()'), 'D1'],
  ['system-rng-core', 'positive', ['det.random'], probe(CORE, 'var generator = SystemRandomNumberGenerator()\n  _ = generator.next()'), 'D1'],
  ['random-in-engine', 'positive', ['det.random'], probe(ENGINE, '_ = Int.random(in: 0..<9)'), 'D1, G1'],

  // The same violations spelled another way. No pass bar yet; each miss gets a rule or a limit.
  ['date-typealias-core', 'evasion', ['det.date-init'], probe(CORE, 'typealias Stamp = Date\n  _ = Stamp()'), 'D1'],
  ['date-init-reference-core', 'evasion', ['det.date-init'], probe(CORE, 'let make = Date.init\n  _ = make()'), 'D1'],
  ['cf-absolute-time-core', 'evasion', ['det.date-init'], probe(CORE, '_ = CFAbsoluteTimeGetCurrent()'), 'D1, G1: a wall-clock read that is not spelled Date'],
  ['nsuuid-core', 'evasion', ['det.uuid-init'], probe(CORE, '_ = NSUUID()'), 'D1'],
  ['task-sleep-generic-core', 'evasion', ['det.task-sleep'], probe(CORE, 'try await Task<Never, Never>.sleep(for: .seconds(1))'), 'D1'],
  ['continuous-clock-sleep-core', 'evasion', ['det.task-sleep'], probe(CORE, 'try await ContinuousClock().sleep(for: .seconds(1))'), 'D1: waiting on a live clock, not \\.continuousClock'],
  ['arc4random-core', 'evasion', ['det.random'], probe(CORE, '_ = arc4random_uniform(6)'), 'D1'],

  // Looks wrong, isn't: outside Core or a client interface, inside text, or through a dependency.
  ['date-init-live', 'near-miss', [], probe(LIVE, '_ = Date()'), 'D1 scope: *Live modules may read the clock'],
  ['uuid-init-log-live', 'near-miss', [], probe(LOG_LIVE, '_ = UUID()'), 'D1 scope'],
  ['task-sleep-live', 'near-miss', [], probe(LIVE, 'try await Task.sleep(for: .seconds(1))'), 'D1 scope'],
  ['date-init-app', 'near-miss', [], probe(APP, '_ = Date()'), 'D1 scope: the app target is not Core'],
  ['date-in-string-core', 'near-miss', [], probe(CORE, '_ = "never call Date() or UUID() here"'), 'D1: string literals don\'t count'],
  ['date-in-comment-core', 'near-miss', [], probe(CORE, '// Date() and Task.sleep would make this depend on the wall clock.\n  _ = 0'), 'D1: comments don\'t count'],
  ['date-since-1970-core', 'near-miss', [], probe(CORE, '_ = Date(timeIntervalSince1970: 0)'), 'D1: a fixed date reads no clock'],
  ['dependency-date-core', 'near-miss', [], probe(CORE, '@Dependency(\\.date.now) var now\n  _ = now'), 'D1: the Do'],
  ['dependency-uuid-core', 'near-miss', [], probe(CORE, '@Dependency(\\.uuid) var uuid\n  _ = uuid()'), 'D1: the Do'],
  ['dependency-clock-core', 'near-miss', [], probe(CORE, '@Dependency(\\.continuousClock) var clock\n  try await clock.sleep(for: .seconds(1))'), 'D1: the Do'],
  ['injected-rng-core', 'near-miss', [], probe(CORE, '@Dependency(\\.withRandomNumberGenerator) var rng\n  _ = rng { Int.random(in: 0..<6, using: &$0) }'), 'D1: the Do'],
  ['local-names-core', 'near-miss', [], probe(CORE, 'let random = 4\n  let sleep = random + 1\n  let shared = sleep\n  _ = shared'), 'D1: a name is not a call'],

  ['sampleapp-baseline', 'clean', [], {}, 'every file in the GREEN baseline'],
]

const arch = [
  // A2: Core imports no UI framework.
  ['swiftui-in-core', 'positive', ['arch.ui-framework-in-core'], prepend(CORE, 'import SwiftUI\n'), 'A2'],
  ['uikit-in-core', 'positive', ['arch.ui-framework-in-core'], prepend(CORE, 'import UIKit\n'), 'A2'],
  ['uikit-in-engine', 'positive', ['arch.ui-framework-in-core'], prepend(ENGINE, 'import UIKit\n'), 'A2: an engine is Core'],
  ['swiftui-scoped-import-core', 'evasion', ['arch.ui-framework-in-core'], prepend(CORE, 'import struct SwiftUI.Color\n'), 'A2'],
  ['uikit-exported-core', 'evasion', ['arch.ui-framework-in-core'], prepend(CORE, '@_exported import UIKit\n'), 'A2'],
  ['swiftui-in-ui', 'near-miss', [], prepend(UI, 'import SwiftUI\n'), 'A2 scope: UI modules import SwiftUI'],
  ['observation-in-core', 'near-miss', [], prepend(CORE, 'import Observation\n'), 'A2: Observation is not a UI framework'],
  ['swiftui-in-comment-core', 'near-miss', [], prepend(CORE, '// No import SwiftUI here: Core stays host-testable.\n'), 'A2'],

  // D2, D3: Core never depends on a Live module or a vendor SDK; Live never depends on a feature.
  ['live-dependency-core', 'positive', ['arch.live-dependency'], addCoreDep('.product(name: "APIClientLive", package: "APIClient")'), 'D2, D3'],
  ['log-live-dependency-core', 'positive', ['arch.live-dependency'], addCoreDep('.product(name: "LogClientLive", package: "LogClient")'), 'D2, D3'],
  [
    'live-depends-on-feature', 'positive', ['arch.live-depends-on-feature'],
    {
      [LOG_PKG]: replaceOnce(
        replaceOnce(base(LOG_PKG), '  dependencies: [\n    .package(', '  dependencies: [\n    .package(path: "../CounterFeature"),\n    .package(', LOG_PKG),
        '.target(name: "LogClientLive", dependencies: ["LogClient"]),',
        '.target(name: "LogClientLive", dependencies: ["LogClient", .product(name: "CounterCore", package: "CounterFeature")]),',
        LOG_PKG,
      ),
    },
    'D2, D3',
  ],
  [
    'vendor-dependency-core', 'positive', ['arch.vendor-dependency'],
    {
      [COUNTER_PKG]: replaceOnce(addCoreDep('.product(name: "DatadogRUM", package: "dd-sdk-ios")')[COUNTER_PKG], '  dependencies: [\n    .package(path: "../APIClient"),\n', '  dependencies: [\n    .package(url: "https://github.com/DataDog/dd-sdk-ios", exact: "2.22.0"),\n    .package(path: "../APIClient"),\n', COUNTER_PKG),
      [CONFIG]: replaceOnce(base(CONFIG), 'vendor_modules = []', 'vendor_modules = ["DatadogRUM"]', CONFIG),
    },
    'D3',
  ],
  [
    'vendor-dependency-live', 'near-miss', [],
    {
      [API_PKG]: replaceOnce(replaceOnce(base(API_PKG), '  dependencies: [\n    .package(path: "../HTTPClient"),\n', '  dependencies: [\n    .package(url: "https://github.com/DataDog/dd-sdk-ios", exact: "2.22.0"),\n    .package(path: "../HTTPClient"),\n', API_PKG), '"APIClient",\n        .product(name: "HTTPClient"', '"APIClient",\n        .product(name: "DatadogRUM", package: "dd-sdk-ios"),\n        .product(name: "HTTPClient"', API_PKG),
      [CONFIG]: replaceOnce(base(CONFIG), 'vendor_modules = []', 'vendor_modules = ["DatadogRUM"]', CONFIG),
    },
    'D3 scope: vendor SDKs belong in *Live',
  ],

  // A1: Core never depends on test support.
  [
    'test-support-dependency-core', 'positive', ['arch.test-support-dependency'],
    {
      ...addCoreDep('"CounterTestSupport"'),
      [COUNTER_PKG]: replaceOnce(
        addCoreDep('"CounterTestSupport"')[COUNTER_PKG],
        '  targets: [\n',
        '  targets: [\n    .target(name: "CounterTestSupport"),\n',
        COUNTER_PKG,
      ),
      'Packages/CounterFeature/Sources/CounterTestSupport/Fixtures.swift': 'public let seededCount = 3\n',
      [CONFIG]: base(CONFIG) + '\n[[modules]]\nname = "CounterTestSupport"\nkind = "test-support"\nreason = "fixtures shared by the counter tests"\n',
    },
    'A1',
  ],
  [
    'test-support-dependency-tests', 'near-miss', [],
    {
      [COUNTER_PKG]: replaceOnce(
        replaceOnce(base(COUNTER_PKG), '  targets: [\n', '  targets: [\n    .target(name: "CounterTestSupport"),\n', COUNTER_PKG),
        'name: "CounterCoreTests",\n      dependencies: [\n',
        'name: "CounterCoreTests",\n      dependencies: [\n        "CounterTestSupport",\n',
        COUNTER_PKG,
      ),
      'Packages/CounterFeature/Sources/CounterTestSupport/Fixtures.swift': 'public let seededCount = 3\n',
      [CONFIG]: base(CONFIG) + '\n[[modules]]\nname = "CounterTestSupport"\nkind = "test-support"\nreason = "fixtures shared by the counter tests"\n',
    },
    'A1 scope: tests may use test support',
  ],

  // D4: a @DependencyClient interface conforms to TestDependencyKey.
  [
    'client-without-test-value', 'positive', ['arch.dependency-client-test-value'],
    replace(CLIENT, `extension APIClient: TestDependencyKey {
  public static let testValue = APIClient()
  public static let previewValue = APIClient(randomFact: {
    Fact(text: "Cats sleep for around 13 to 14 hours a day.")
  })
}
`, ''),
    'D4',
  ],
  [
    'client-test-value-other-file', 'near-miss', [],
    {
      ...replace(CLIENT, `extension APIClient: TestDependencyKey {
  public static let testValue = APIClient()
  public static let previewValue = APIClient(randomFact: {
    Fact(text: "Cats sleep for around 13 to 14 hours a day.")
  })
}
`, ''),
      'Packages/APIClient/Sources/APIClient/APIClient+TestValue.swift': 'import Dependencies\n\nextension APIClient: TestDependencyKey {\n  public static let testValue = APIClient()\n}\n',
    },
    'D4: the conformance may live in another file of the interface module',
  ],

  // C5: no MainActor default isolation in Core.
  ['main-actor-default-core', 'positive', ['arch.core-main-actor-isolation'], replace(COUNTER_PKG, `        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ]
    ),
    // iOS-only`, `        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ],
      swiftSettings: [.defaultIsolation(MainActor.self)]
    ),
    // iOS-only`), 'C5'],
  ['main-actor-unsafe-flag-core', 'evasion', ['arch.core-main-actor-isolation'], replace(COUNTER_PKG, `        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ]
    ),
    // iOS-only`, `        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ],
      swiftSettings: [.unsafeFlags(["-default-isolation", "MainActor"])]
    ),
    // iOS-only`), 'C5'],
  ['main-actor-default-ui', 'near-miss', [], replace(COUNTER_PKG, `      name: "CounterUI",
      dependencies: [
        "CounterCore",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ]
    ),`, `      name: "CounterUI",
      dependencies: [
        "CounterCore",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ],
      swiftSettings: [.defaultIsolation(MainActor.self)]
    ),`), 'C5 scope: UI modules may default to MainActor'],

  // A1, A3: every non-TCA Core is declared, and every declared module exists.
  [
    'engine-undeclared', 'positive', ['arch.undeclared-kind'],
    replace(CONFIG, `
[[modules]]
name = "GameEngine"
kind = "engine"
reason = "tic-tac-toe rules as a pure (State, Input) -> State step with a seeded RNG; a reducer adds ceremony only"
`, ''),
    'A1',
  ],
  [
    'new-core-undeclared', 'positive', ['arch.undeclared-kind'],
    {
      ...replace(COUNTER_PKG, '  targets: [\n', '  targets: [\n    .target(name: "CounterMath"),\n'),
      'Packages/CounterFeature/Sources/CounterMath/Clamp.swift': 'public func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {\n  min(max(value, range.lowerBound), range.upperBound)\n}\n',
    },
    'A1',
  ],
  [
    'new-core-declared', 'near-miss', [],
    {
      ...replace(COUNTER_PKG, '  targets: [\n', '  targets: [\n    .target(name: "CounterMath"),\n'),
      'Packages/CounterFeature/Sources/CounterMath/Clamp.swift': 'public func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {\n  min(max(value, range.lowerBound), range.upperBound)\n}\n',
      [CONFIG]: base(CONFIG) + '\n[[modules]]\nname = "CounterMath"\nkind = "library"\nreason = "pure clamping helpers shared by features"\n',
    },
    'A1: declared in config',
  ],
  ['config-names-missing-module', 'positive', ['arch.config-module-mismatch'], { [CONFIG]: base(CONFIG) + '\n[[modules]]\nname = "SearchCore"\nkind = "library"\nreason = "module was deleted but its entry stayed"\n' }, 'A1, A3'],

  // G1, P10: every engine has a replay test.
  [
    'engine-without-replay-test', 'positive', ['arch.engine-replay-test'],
    { [ENGINE_TESTS]: base(ENGINE_TESTS).slice(0, base(ENGINE_TESTS).indexOf('struct GameEngineReplayTests')) },
    'G1, playbook P10',
  ],
  [
    'engine-replay-named-only', 'evasion', ['arch.engine-replay-test'],
    {
      [ENGINE_TESTS]:
        base(ENGINE_TESTS).slice(0, base(ENGINE_TESTS).indexOf('struct GameEngineReplayTests')) +
        'struct GameEngineReplayTests {\n  @Test("replay returns a board — catches replay crashing")\n  func replayRuns() {\n    #expect(GameEngine.replay(seed: 1, inputs: []).board.count == 9)\n  }\n}\n',
    },
    'G1: a test named replay that never compares 2 replays',
  ],

  ['sampleapp-baseline', 'clean', [], {}, 'every module in the GREEN baseline'],
]

// Prose seeds are whole documents. Each positive plants 1 rule in otherwise clean text.
const doc = (...lines) => ({ 'doc.md': `# Seed\n\n${lines.join('\n')}\n` })
const prose = [
  ['adverb', 'positive', ['prose.adverb'], doc('The gate quickly rejects the change.'), 'spec §6.2: adverbs'],
  ['adverb-silently', 'positive', ['prose.adverb'], doc('The hook fails silently when the binary is missing.'), 'spec §6.2'],
  ['em-dash', 'positive', ['prose.em-dash'], doc('The runner stops — it has no report to read.'), 'spec §6.2: em-dashes'],
  ['number-word', 'positive', ['prose.number-word'], doc('The gate runs three checks on every push.'), 'spec §6.2: number words where numerals fit'],
  ['number-word-times', 'positive', ['prose.number-word'], doc('The hook retries five times before it stops.'), 'spec §6.2'],
  ['passive-by', 'positive', ['prose.passive-voice'], doc('The report is written by the hook.'), 'spec §6.2: passive voice'],
  ['passive-irregular', 'positive', ['prose.passive-voice'], doc('The cache was built at startup.'), 'spec §6.2'],
  ['filler-in-order-to', 'positive', ['prose.filler'], doc('Run the gate in order to see the findings.'), 'spec §6.2: filler'],
  ['filler-worth-noting', 'positive', ['prose.filler'], doc("It's worth noting that the gate reads the config first."), 'spec §6.2'],
  ['jargon-leverage', 'positive', ['prose.jargon'], doc('The runner can leverage the cache between runs.'), 'spec §6.2: business jargon'],
  ['jargon-seamless', 'positive', ['prose.jargon'], doc('The hook gives a seamless handoff to the reviewer.'), 'spec §6.2'],
  ['sentence-length', 'positive', ['prose.sentence-length'], doc(`The gate reads the config and ${'then checks each module and '.repeat(8)}then writes the report to disk.`), 'spec §6.2: sentence ceiling (default 40 words)'],

  ['em-dash-double-hyphen', 'evasion', ['prose.em-dash'], doc('The runner stops -- it has no report to read.'), 'suites.md: an em-dash as --'],
  ['en-dash-spaced', 'evasion', ['prose.em-dash'], doc('The runner stops – it has no report to read.'), 'an en dash used as an em-dash'],
  ['adverb-in-heading', 'evasion', ['prose.adverb'], { 'doc.md': '# Seed\n\n## Quickly start the gate\n\nRun the gate.\n' }, 'suites.md: an adverb in a heading'],
  ['passive-get', 'evasion', ['prose.passive-voice'], doc('The report gets written by the hook.'), 'a get-passive; the rule documents this as a known miss'],
  ['passive-unlisted-participle', 'evasion', ['prose.passive-voice'], doc('The change was undone by the hook.'), 'an irregular participle outside the list'],
  ['jargon-inflected', 'evasion', ['prose.jargon'], doc('The plan synergizes the gates.'), 'an inflection outside the list'],

  ['ly-non-adverbs', 'near-miss', [], doc('The early reply applies only to the family of rules.'), 'words ending in -ly that are not adverbs'],
  ['number-phrases', 'near-miss', [], doc('Pick one of the checks. Run them one by one.'), 'number words inside a phrase'],
  ['number-sentence-start', 'near-miss', [], doc('Three checks run on every push.'), 'judgment: a numeral cannot start a sentence'],
  ['state-adjective', 'near-miss', [], doc('The lock is closed until the run ends.'), 'a state, not a passive'],
  ['verdict-red', 'near-miss', [], doc('The verdict is RED when a test fails.'), 'RED is a verdict, not a participle'],
  ['verdict-green', 'near-miss', [], doc('The run is GREEN, so the hook stays quiet.'), 'GREEN is a verdict'],
  ['inline-code', 'near-miss', [], doc('The lexicon lists `quickly`, `in order to` and `leverage` as findings.'), 'inline code is skipped'],
  ['fenced-code', 'near-miss', [], { 'doc.md': '# Seed\n\nThe snippet shows the tells.\n\n```text\nThe report is written quickly — in order to leverage three caches.\n```\n' }, 'fenced code is skipped'],
  ['table-cell', 'near-miss', [], { 'doc.md': '# Seed\n\nThe table lists the tells.\n\n| Tell | Rule |\n|---|---|\n| leverage, quickly | jargon, adverb |\n' }, 'tables are skipped'],
  ['html-comment', 'near-miss', [], doc('The gate reads the config.', '', '<!-- It should be noted that this is very rough. -->'), 'HTML comments are skipped'],
  ['tier-tail', 'near-miss', [], doc('- test-count-floor: tapping minus at 0 keeps 0 — tier T1'), 'spec §5.3: the tier tail is syntax'],
  ['frontmatter', 'near-miss', [], { 'doc.md': '---\ndescription: quickly leverage three caches in order to win\n---\n\n# Seed\n\nThe gate reads the config.\n' }, 'frontmatter is skipped'],

  // From the docs/ audit: findings the operator labelled false positives. Labels need a person's review.
  ['quoted-mention-filler', 'near-miss', [], doc('AI-prose tells include the phrase "it\'s worth noting".'), 'wild, standards.md: a quoted phrase is mentioned, not used'],
  ['quoted-mention-adverb', 'near-miss', [], doc('Comment tells include AI-prose words such as "importantly".'), 'wild, standards.md: a quoted word is mentioned, not used'],
  ['just-meaning-only', 'near-miss', [], doc('The two audiences need different guidance, not just different files.'.replace('two', '2')), 'wild, ADR 0002: "just" means "only" here'],
  ['just-meaning-recently', 'near-miss', [], doc('The check flags a value the test just constructed.'), 'wild, foundation design: "just" means "a moment ago" here'],
  ['one-as-pronoun', 'near-miss', [], doc('A test that forgets to override one fails instead of passing.'), 'wild, testing-playbook: "one" is a pronoun'],
  ['evals-docs', 'clean', [], { paths: ['evals/README.md', 'evals/apps.md', 'evals/components.md', 'evals/design.md', 'evals/research.md', 'evals/runbook.md', 'evals/suites.md'] }, 'eval docs written under the prose skill'],
]

function write(gate, [name, kind, expect, files, source]) {
  const dir = join(corpora, gate, name)
  rmSync(dir, { recursive: true, force: true })
  mkdirSync(dir, { recursive: true })
  const labels = { kind, expect, source }
  if (source.startsWith('wild') || source.startsWith('judgment')) labels.labelledBy = 'operator; needs a person to confirm'
  if (gate === 'prose' && files.paths) {
    labels.paths = files.paths
  } else {
    for (const [path, text] of Object.entries(files)) {
      const target = gate === 'prose' ? join(dir, path) : join(dir, 'files', path)
      mkdirSync(dirname(target), { recursive: true })
      writeFileSync(target, text)
    }
  }
  writeFileSync(join(dir, 'labels.json'), JSON.stringify(labels, null, 2) + '\n')
}

for (const gate of ['lint', 'arch', 'prose']) rmSync(join(corpora, gate), { recursive: true, force: true })
for (const seed of lint) write('lint', seed)
for (const seed of arch) write('arch', seed)
for (const seed of prose) write('prose', seed)
console.log(`lint ${lint.length}, arch ${arch.length}, prose ${prose.length} cases written to evals/corpora/`)
