# `design-diff` self-test seeds

Each case names two revisions of one design doc, `revisions/1.md` and `revisions/2.md`. The
runner commits both, in order, to a throwaway git repository, then builds an in-memory `plan.json`
whose `clarifyChain` records the edit as a clarify (a real, un-clarified edit implicitly claims
this): `approval.designSha` and the link's `fromSha`/`toSha` are `DesignSha.of` each revision's
text, computed at self-test time, never hand-copied.

`genuine-clarify/` only edits prose outside every protected section, so the chain verifies.
`requirement-edit-posing-as-clarify/` edits a `req-` line, which `design-diff` classifies as an
amend; the chain catches the mismatch and reports it broken.
`requirement-moved-out-of-requirements/` moves a `req-` bullet, unchanged, from Requirements into
Risks, and `changelog-rewritten-posing-as-clarify/` edits an existing Changelog entry. Both are
amends, so the chain reports them broken.
