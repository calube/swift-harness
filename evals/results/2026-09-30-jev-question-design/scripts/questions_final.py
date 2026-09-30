"""The proposed Jev request for test-quality@2: only the questions the set would send, in the
named-field state (s1). Wording is taken from the round-2 objects unchanged."""
import questions_r1 as r1
import questions_r2 as r2

TIER = {"type": "choice",
        "instructions": ("Which tier does this test belong in? T1: host unit test of logic "
                         "(reducers, pure functions, clients with fakes). T2: simulator test of "
                         "rendering or platform integration (snapshots, views). T3: end-to-end UI "
                         "flow (XCUITest)."),
        "criteria": {"T1": None, "T2": None, "T3": None}}

FINAL = {
    "tier": TIER,
    "fails-if-broken.runs-changed-code": r2.FIB_R2_S1["f2_runs_changed"],
    "fails-if-broken.checks-named-result": r2.FIB_R2_S1["f2_checks_named"],
    "name-specificity.catches-adds": r2.NAME_ADDS,
    "asserts-implementation.call-details": r2.AI_R2_S1["a2_call_details"],
    "asserts-implementation.private-state": r1.AI_S1["a_private_state"],
    "asserts-implementation.log-text": r1.AI_S1["a_log_text"],
}


def battery(kind, state):
    assert kind == "s1"
    return dict(FINAL)
