# `build merge` self-test seeds

The runner builds a throwaway repository with one commit on `main`, a task branch one commit
ahead, and a build run whose last merge event left `main` at that first commit and whose
`return-check` event checked the task's return GREEN at the branch tip. It then runs
`build merge`'s merge flow. An `after-last-merge.txt` in a case is committed onto `main` first, as
another session's merge would be.

`main-moved` has that file, so the merge is refused. `valid` doesn't, so the task branch merges.
The runner names a refusal by the report's closed `reason`, as `build-merge.<reason>`.
