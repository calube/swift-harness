# `build merge` self-test seeds

The runner builds a throwaway repository with one commit on `main`, a task branch one commit
ahead, and a build run whose last merge event left `main` at that first commit. It then runs
`build merge`'s merge flow. An `after-last-merge.txt` in a case is committed onto `main` first, as
another session's merge would be.

`main-moved` has that file, so the merge is refused. `valid` doesn't, so the task branch merges.
`BuildMergeReport` has no closed refusal reason yet, so the runner tells the moved-main refusal
apart by its message.
