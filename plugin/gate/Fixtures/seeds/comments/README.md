# `comments` self-test seeds

Each case's `Seed.swift` is staged (never committed — `comments` reads the index) into a throwaway
repo. `known-id-leak`'s `known-id.txt` names a ledger task id the runner seeds under that repo's
own common dir, so `comments.leaked-id`'s known-id half fires without touching this checkout's
shared plan state; `codename-leak` needs no ledger, since a codename-shaped token is recognised on
its own.
