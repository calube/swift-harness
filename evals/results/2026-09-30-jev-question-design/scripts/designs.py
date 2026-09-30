"""Candidate designs: each maps a case's answers to the flagged probability."""
from score import noul as N, prob as P

FIB = {
    "base (s0, today)": lambda a: 1 - N(a, "s0", "base_fib"),
    "s0 calls_changed": lambda a: 1 - N(a, "s0", "f_calls_changed_s0"),
    "s0 asserts_changed": lambda a: 1 - N(a, "s0", "f_asserts_changed_s0"),
    "s0 NOT(calls AND asserts)": lambda a: 1 - min(N(a, "s0", "f_calls_changed_s0"),
                                                   N(a, "s0", "f_asserts_changed_s0")),
    "s1 base wording": lambda a: 1 - N(a, "s1", "f_base_s1"),
    "s1 calls_changed": lambda a: 1 - N(a, "s1", "f_calls_changed"),
    "s1 asserts_changed": lambda a: 1 - N(a, "s1", "f_asserts_changed"),
    "s1 double_only": lambda a: N(a, "s1", "f_double_only"),
    "s1 weak_assert": lambda a: N(a, "s1", "f_weak_assert"),
    "s1 counterfactual": lambda a: 1 - N(a, "s1", "f_counterfactual"),
    "s1 choice none": lambda a: P(a, "s1", "f_which_assertion", "none"),
    "s1 NOT(calls AND asserts)": lambda a: 1 - min(N(a, "s1", "f_calls_changed"),
                                                   N(a, "s1", "f_asserts_changed")),
    "s1 asserts OR weak": lambda a: max(1 - N(a, "s1", "f_asserts_changed"),
                                        N(a, "s1", "f_weak_assert")),
    "s1 NOT(calls AND asserts) OR weak": lambda a: max(
        1 - min(N(a, "s1", "f_calls_changed"), N(a, "s1", "f_asserts_changed")),
        N(a, "s1", "f_weak_assert")),
    "s1 choice-none OR weak": lambda a: max(P(a, "s1", "f_which_assertion", "none"),
                                            N(a, "s1", "f_weak_assert")),
}

NAME = {
    "base (s0, today)": lambda a: P(a, "s0", "base_name", "0"),
    "probe criteria (s0)": lambda a: P(a, "s0", "probe_name", "0"),
    "s1 structured score": lambda a: P(a, "s1", "n_score_struct", "0"),
    "s1 restates": lambda a: N(a, "s1", "n_restates"),
    "s1 NOT symptom AND NOT condition": lambda a: (1 - N(a, "s1", "n_symptom"))
                                                  * (1 - N(a, "s1", "n_condition")),
    "s1 restates OR (no symptom, no cond)": lambda a: max(
        N(a, "s1", "n_restates"),
        (1 - N(a, "s1", "n_symptom")) * (1 - N(a, "s1", "n_condition"))),
}

AI = {
    "base (s0, today)": lambda a: N(a, "s0", "base_ai"),
    "s1 base+criteria": lambda a: N(a, "s1", "a_base_crit"),
    "s1 call_details": lambda a: N(a, "s1", "a_call_details"),
    "s1 private_state": lambda a: N(a, "s1", "a_private_state"),
    "s1 log_text": lambda a: N(a, "s1", "a_log_text"),
    "s1 any(call, private, log)": lambda a: max(N(a, "s1", "a_call_details"),
                                               N(a, "s1", "a_private_state"),
                                               N(a, "s1", "a_log_text")),
}

DESIGNS = {"fails-if-broken": FIB, "name-specificity": NAME, "asserts-implementation": AI}


# ------------------------------------------------------------------ round 2 designs
def _fib_max(a, kind, sfx):
    runs = N(a, kind, "f2_runs_changed" + sfx)
    named = N(a, kind, "f2_checks_named" + sfx)
    weak = N(a, kind, "f2_weak" + sfx) if sfx else N(a, kind, "f_weak_assert")
    return max(1 - runs, 1 - named, weak)


FIB2 = {
    "s0 runs_changed v2": lambda a: 1 - N(a, "s0", "f2_runs_changed_s0"),
    "s0 checks_named": lambda a: 1 - N(a, "s0", "f2_checks_named_s0"),
    "s0 readback": lambda a: N(a, "s0", "f2_readback_s0"),
    "s0 weak": lambda a: N(a, "s0", "f2_weak_s0"),
    "s0 NOT runs OR NOT named OR weak": lambda a: _fib_max(a, "s0", "_s0"),
    "s0 NOT runs OR NOT named": lambda a: max(1 - N(a, "s0", "f2_runs_changed_s0"),
                                              1 - N(a, "s0", "f2_checks_named_s0")),
    "s0 NOT runs OR weak": lambda a: max(1 - N(a, "s0", "f2_runs_changed_s0"),
                                         N(a, "s0", "f2_weak_s0")),
    "s1 runs_changed v2": lambda a: 1 - N(a, "s1", "f2_runs_changed"),
    "s1 checks_named": lambda a: 1 - N(a, "s1", "f2_checks_named"),
    "s1 readback": lambda a: N(a, "s1", "f2_readback"),
    "s1 NOT runs OR NOT named OR weak": lambda a: _fib_max(a, "s1", ""),
    "s1 NOT runs OR NOT named": lambda a: max(1 - N(a, "s1", "f2_runs_changed"),
                                              1 - N(a, "s1", "f2_checks_named")),
}

NAME2 = {
    "s0 restates": lambda a: N(a, "s0", "n2_restates_s0"),
    "s0 restates OR (no symptom, no cond)": lambda a: max(
        N(a, "s0", "n2_restates_s0"),
        (1 - N(a, "s0", "n2_symptom_s0")) * (1 - N(a, "s0", "n2_condition_s0"))),
    "s0 NOT symptom AND NOT condition": lambda a: (1 - N(a, "s0", "n2_symptom_s0"))
                                                  * (1 - N(a, "s0", "n2_condition_s0")),
    "s1 choice adds=nothing": lambda a: P(a, "s1", "n2_adds", "nothing"),
}

AI2 = {
    "s0 call_details v2": lambda a: N(a, "s0", "a2_call_details_s0"),
    "s0 any(call v2, private, log)": lambda a: max(N(a, "s0", "a2_call_details_s0"),
                                                  N(a, "s0", "a2_private_state_s0"),
                                                  N(a, "s0", "a2_log_text_s0")),
    "s1 call_details v2": lambda a: N(a, "s1", "a2_call_details"),
    "s1 any(call v2, private, log)": lambda a: max(N(a, "s1", "a2_call_details"),
                                                  N(a, "s1", "a_private_state"),
                                                  N(a, "s1", "a_log_text")),
}

FIB.update(FIB2)
NAME.update(NAME2)
AI.update(AI2)
