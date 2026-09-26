## `prose`

26 of 36 cases match their labels.

| Rule | Recall, positives | Recall, evasions | False positives | Cases |
|---|---|---|---|---|
| `prose.adverb` | 2/2 | 1/1 | 1/33 | quoted-mention-adverb |
| `prose.em-dash` | 1/1 | 1/2 | 0/33 |  |
| `prose.filler` | 2/2 | – | 3/34 | just-meaning-only, just-meaning-recently, quoted-mention-filler |
| `prose.jargon` | 2/2 | 0/1 | 0/33 |  |
| `prose.number-word` | 2/2 | – | 2/34 | number-sentence-start, one-as-pronoun |
| `prose.passive-voice` | 2/2 | 0/2 | 0/32 |  |
| `prose.sentence-length` | 1/1 | – | 0/35 |  |

| Case | Kind | Missed | Unexpected |
|---|---|---|---|
| `en-dash-spaced` | evasion | prose.em-dash |  |
| `jargon-inflected` | evasion | prose.jargon |  |
| `just-meaning-only` | near-miss |  | prose.filler |
| `just-meaning-recently` | near-miss |  | prose.filler |
| `number-sentence-start` | near-miss |  | prose.number-word |
| `one-as-pronoun` | near-miss |  | prose.number-word |
| `passive-get` | evasion | prose.passive-voice |  |
| `passive-unlisted-participle` | evasion | prose.passive-voice |  |
| `quoted-mention-adverb` | near-miss |  | prose.adverb |
| `quoted-mention-filler` | near-miss |  | prose.filler |

## `lint`

36 of 41 cases match their labels.

| Rule | Recall, positives | Recall, evasions | False positives | Cases |
|---|---|---|---|---|
| `det.async-after` | 2/2 | – | 0/39 |  |
| `det.date-init` | 6/6 | 0/3 | 0/32 |  |
| `det.random` | 6/6 | 1/1 | 0/34 |  |
| `det.task-sleep` | 3/3 | 1/2 | 0/36 |  |
| `det.uuid-init` | 4/4 | 0/1 | 0/36 |  |

| Case | Kind | Missed | Unexpected |
|---|---|---|---|
| `cf-absolute-time-core` | evasion | det.date-init |  |
| `continuous-clock-sleep-core` | evasion | det.task-sleep |  |
| `date-init-reference-core` | evasion | det.date-init |  |
| `date-typealias-core` | evasion | det.date-init |  |
| `nsuuid-core` | evasion | det.uuid-init |  |

## `arch`

25 of 27 cases match their labels.

| Rule | Recall, positives | Recall, evasions | False positives | Cases |
|---|---|---|---|---|
| `arch.config-module-mismatch` | 1/1 | – | 0/26 |  |
| `arch.core-main-actor-isolation` | 1/1 | 1/1 | 0/25 |  |
| `arch.dependency-client-test-value` | 1/1 | – | 0/26 |  |
| `arch.engine-replay-test` | 0/1 | 0/1 | 0/25 |  |
| `arch.live-dependency` | 2/2 | – | 0/25 |  |
| `arch.live-depends-on-feature` | 1/1 | – | 0/26 |  |
| `arch.test-support-dependency` | 1/1 | – | 0/26 |  |
| `arch.ui-framework-in-core` | 3/3 | 2/2 | 0/22 |  |
| `arch.undeclared-kind` | 2/2 | – | 0/25 |  |
| `arch.vendor-dependency` | 1/1 | – | 0/26 |  |

| Case | Kind | Missed | Unexpected |
|---|---|---|---|
| `engine-replay-named-only` | evasion | arch.engine-replay-test |  |
| `engine-without-replay-test` | positive | arch.engine-replay-test |  |
