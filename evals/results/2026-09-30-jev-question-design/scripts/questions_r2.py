"""Round 2: every round-1 question again (a second repeat), plus refined sub-questions."""
import questions_r1 as r1

NAME_REF_S0 = ("the test's name (the string in `@Test(...)`, or the function name when there is "
               "none)")

# ------------------------------------------------------------------ fails-if-broken
RUNS_CHANGED = {
    "true": "The test runs at least one line the change adds or modifies.",
    "false": {"what": "The test never runs the changed lines",
              "examples": ["it only calls closures, fakes, stubs, mocks or spies it set up itself",
                           "it calls a method on a test double that has the same name as the "
                           "changed function",
                           "it calls code the change does not touch"]}}


def runs_changed(test, code):
    return {"type": "noul", "instructions": {
        "question": f"Does {test} run a function, property or reducer action that {code} adds "
                    "or modifies?",
        "focus": "Calling a method on a fake, stub, mock or spy does not count, even when the "
                 "method has the same name as changed code."},
        "criteria": RUNS_CHANGED}


def checks_named_result(test, name):
    return {"type": "noul", "instructions": {
        "question": f"Does an assertion in {test} compare the result that {name} describes with "
                    "an expected value?",
        "focus": "Find the value or state the name talks about, then look for an assertion on it."},
        "criteria": {
            "true": {"what": "An assertion checks the very value, state or output the name "
                             "talks about",
                     "examples": ["the name is about a total and the test asserts the total",
                                  "the name is about a message shown and the test asserts that "
                                  "message in state",
                                  "the name says a method is called and the test asserts the call"]},
            "false": {"what": "The result the name describes is never compared",
                      "examples": ["the assertions check other fields of the same object",
                                   "the assertions check setup values or a test double's own value",
                                   "the only assertion checks that something exists or is true"]}}}


def reads_back_double(test):
    return {"type": "noul", "instructions": {
        "question": f"Does every assertion in {test} compare a value the test gave to a fake, "
                    "stub or mock with what that same test double hands back?",
        "focus": "A spy that records calls made by the production code is not handing back a "
                 "value the test gave it."},
        "criteria": {
            "true": "The asserted values go into a test double and come straight back out, "
                    "without production code transforming them.",
            "false": "At least one asserted value is computed or recorded by production code."}}


FIB_R2_S0 = {
    "f2_runs_changed_s0": runs_changed("the test in `subject`", "the change in `context`"),
    "f2_checks_named_s0": checks_named_result("`subject`", NAME_REF_S0),
    "f2_readback_s0": reads_back_double("`subject`"),
    "f2_weak_s0": {"type": "noul", "instructions":
        "Do the assertions in `subject` only check that a value exists, is non-nil or non-empty, "
        "is always true, or equals itself?",
        "criteria": r1.FIB_S1["f_weak_assert"]["criteria"]},
}
FIB_R2_S1 = {
    "f2_runs_changed": runs_changed("`test_source`", "`code_under_test`"),
    "f2_checks_named": checks_named_result("`assertions`", "`test_name.behavior`"),
    "f2_readback": reads_back_double("`assertions`"),
}

# ------------------------------------------------------------------ name-specificity
NAME_ADDS = {"type": "choice", "instructions": {
    "question": "What does `test_name.catches` say beyond `test_name.behavior`?",
    "focus": "Judge the wording of the name only."},
    "criteria": {
        "nothing": {"what": "Only that the behavior fails, breaks or does not happen, or failures, "
                            "bugs, problems or regressions in general; or there is no catches part",
                    "examples": ["fetchUser returns the user — catches fetchUser not returning the "
                                 "user", "settings works — catches settings bugs",
                                 "encodes the date — catches encoding failures", "testRefresh"]},
        "condition": {"what": "A specific input, case or area where it goes wrong, but not what "
                              "anyone would see",
                      "examples": ["catches a bug in leap years",
                                   "catches wrong handling of offline mode"]},
        "symptom": {"what": "What a user or caller would see go wrong",
                    "examples": ["catches shoppers billed twice for one order",
                                 "catches the map staying blank after location access is granted"]},
    }}

NAME_R2_S0 = {
    "n2_restates_s0": {"type": "noul", "instructions": {
        "question": f"Does {NAME_REF_S0} only say that the behavior fails, breaks, or does not "
                    "happen, without naming what goes wrong?"},
        "criteria": r1.NAME_S1["n_restates"]["criteria"]},
    "n2_symptom_s0": {"type": "noul", "instructions": {
        "question": f"Does {NAME_REF_S0} describe what a user or caller would observe going wrong?",
        "focus": r1.NAME_S1["n_symptom"]["instructions"]["focus"]},
        "criteria": r1.NAME_S1["n_symptom"]["criteria"]},
    "n2_condition_s0": {"type": "noul", "instructions":
        f"Does {NAME_REF_S0} name a specific input, condition or case, beyond the name of the "
        "feature or action?", "criteria": r1.NAME_S1["n_condition"]["criteria"]},
}

# ------------------------------------------------------------------ asserts-implementation
CALL_DETAILS_V2 = {
    "true": r1.AI_S1["a_call_details"]["criteria"]["true"],
    "false": {"what": "Asserts results the feature produces",
              "not_for": ["the test itself calling a mock or stub and comparing what it returns",
                          "the value the feature saves, sends or shows when that value is the "
                          "feature's result",
                          "TestStore send or receive with the state it produces",
                          "advancing a test clock and checking what happened after the delay"]}}


def call_details(test):
    return {"type": "noul", "instructions": {
        "question": f"Does an assertion in {test} check how many times, in what order, or with "
                    "which arguments the production code called a collaborator, spy or helper?"},
        "criteria": CALL_DETAILS_V2}


AI_R2_S0 = {
    "a2_call_details_s0": call_details("`subject`"),
    "a2_private_state_s0": {"type": "noul", "instructions":
        "Does an assertion in `subject` read a private, underscored or testing-only property that "
        "callers of the code cannot see?", "criteria": r1.AI_S1["a_private_state"]["criteria"]},
    "a2_log_text_s0": {"type": "noul", "instructions":
        "Does an assertion in `subject` compare the exact text of a log or debug message?"},
}
AI_R2_S1 = {"a2_call_details": call_details("`assertions`")}


def battery(kind, state):
    qs = r1.battery(kind, state)
    if kind == "s0":
        qs.update({**FIB_R2_S0, **NAME_R2_S0, **AI_R2_S0})
    else:
        qs.update({**FIB_R2_S1, **AI_R2_S1, "n2_adds": NAME_ADDS})
    return qs
