"""Round 1 question battery. Each state kind gets one request per case holding every question."""

# ---- baseline: exactly what JevRequest.body sends for test-quality@1 today
BASE_FIB = "Would this test fail if the behavior it names were broken?"
BASE_NAME = ("How specific is the regression the test's name says it catches? vague: names no "
             "symptom or restates the behavior; partial: names an area but not the symptom; "
             "specific: names a user- or caller-visible symptom.")
BASE_AI = ("Does the test assert implementation details (private call order, internal state, "
           "exact log text, which collaborator was called) rather than observable behavior?")

BASELINE = {
    "base_fib": {"type": "noul", "instructions": BASE_FIB},
    "base_name": {"type": "score", "instructions": BASE_NAME,
                  "criteria": ["vague", "partial", "specific"]},
    "base_ai": {"type": "noul", "instructions": BASE_AI},
    # what the throwaway probe sent: level descriptions instead of bare level names
    "probe_name": {"type": "score", "instructions": BASE_NAME, "criteria": [
        "vague: names no symptom or restates the behavior",
        "partial: names an area but not the symptom",
        "specific: names a user- or caller-visible symptom"]},
}

# ---- s0 decomposition: same state as today, paths `subject` / `context`
S0_DECOMP = {
    "f_calls_changed_s0": {"type": "noul", "instructions":
        "Does the test in `subject` call a function, read a property, or send an action that the "
        "change in `context` adds or modifies?",
        "criteria": {
            "true": "The test runs at least one line the change adds or modifies.",
            "false": "The test only calls closures, fakes, stubs or mocks it set up itself, or code "
                     "the change does not touch."}},
    "f_asserts_changed_s0": {"type": "noul", "instructions":
        "Does an assertion in `subject` check a value that the changed lines in `context` compute "
        "or set?",
        "criteria": {
            "true": "An asserted value is returned, set or emitted by the changed lines.",
            "false": "Every assertion checks a value the test built itself, a value a test double "
                     "returned directly, a field the changed lines never set, or only that a value "
                     "exists."}},
}

# ---- s1: named fields, parsed name parts and assertions
FIB_S1 = {
    "f_calls_changed": {"type": "noul", "instructions": {
        "question": "Does `test_source` call a function, read a property, or send an action that "
                    "`code_under_test` adds or modifies?",
        "focus": "Code the test sets up itself (closures, fakes, stubs, mocks, spies) is not "
                 "`code_under_test`."},
        "criteria": {
            "true": "The test runs at least one line that `code_under_test` adds or modifies.",
            "false": "The test only calls closures, fakes, stubs, mocks or spies it set up itself, "
                     "or code that `code_under_test` does not touch."}},
    "f_asserts_changed": {"type": "noul", "instructions": {
        "question": "Does at least one entry in `assertions` check a value that the changed lines "
                    "in `code_under_test` compute or set?",
        "focus": "Trace each asserted value back to where it was produced."},
        "criteria": {
            "true": {"what": "An asserted value is returned, set or emitted by the changed lines",
                     "examples": ["the changed property `subtotal` is compared with 42",
                                  "a TestStore state field the changed reducer case sets"]},
            "false": {"what": "No assertion reads a value the changed lines produce",
                      "examples": ["the test compares a value it built itself",
                                   "the value came straight from a fake, stub or mock",
                                   "the asserted field is one the changed lines never set",
                                   "the assertion only checks that a value exists or is non-empty"]}}},
    "f_double_only": {"type": "noul", "instructions": {
        "question": "Is every value checked in `assertions` produced by the test itself or by a "
                    "test double, rather than by `code_under_test`?",
        "focus": "A test double is a fake, stub, mock, spy or closure the test configures."},
        "criteria": {
            "true": "Each asserted value was built by the test or returned by a test double.",
            "false": "At least one asserted value is produced by `code_under_test`."}},
    "f_weak_assert": {"type": "noul", "instructions":
        "Do the `assertions` only check that a value exists, is non-nil or non-empty, is always "
        "true, or equals itself?",
        "criteria": {
            "true": "No assertion compares a result with a specific expected value.",
            "false": "At least one assertion compares a result with a specific expected value."}},
    "f_counterfactual": {"type": "noul", "instructions":
        "If the changed lines in `code_under_test` produced a wrong value, would an entry in "
        "`assertions` fail?"},
    "f_base_s1": {"type": "noul", "instructions":
        "Would `test_source` fail if the behavior `test_name` names were broken?"},
}

NAME_S1 = {
    "n_restates": {"type": "noul", "instructions": {
        "question": "Does `test_name` only say that the behavior fails, breaks, or does not happen, "
                    "without naming what goes wrong?",
        "focus": "Read `test_name.catches` against `test_name.behavior`."},
        "criteria": {
            "true": {"what": "The catches part negates the behavior or names generic failures",
                     "examples": ["fetchUser returns the user — catches fetchUser not "
                                  "returning the user", "settings works — catches settings bugs",
                                  "encodes the date — catches encoding failures",
                                  "a test named testRefresh with no description"]},
            "false": {"what": "The name says what a user or caller would see, or names a specific "
                              "condition where it goes wrong",
                      "examples": ["catches shoppers billed twice for one order",
                                   "catches a bug in leap years"]}}},
    "n_symptom": {"type": "noul", "instructions": {
        "question": "Does `test_name` describe what a user or caller would observe going wrong?",
        "focus": "An observable symptom: a wrong value, a wrong screen, a stuck spinner, a missing "
                 "message, lost data, an extra request."},
        "criteria": {
            "true": {"what": "Names a concrete observable symptom",
                     "examples": ["catches shoppers billed twice for one order",
                                  "catches the map staying blank after location access is granted"]},
            "false": {"what": "Names only the feature, a condition, or failure in general",
                      "examples": ["catches encoding failures", "catches a bug in leap years",
                                   "catches refresh not refreshing"]}}},
    "n_condition": {"type": "noul", "instructions":
        "Does `test_name` name a specific input, condition or case, beyond the name of the "
        "feature or action?",
        "criteria": {
            "true": "Names a particular input or case, such as a leap year, offline mode, "
                    "a zero quantity, or a timeout.",
            "false": "Names only the feature, function or action."}},
    "n_score_struct": {"type": "score", "instructions": {
        "question": "How specific is the regression that `test_name` says the test catches?",
        "focus": "Judge the name only, not the test body."},
        "criteria": [
            {"what": "vague: names no symptom, or only restates the behavior",
             "examples": ["fetchUser returns the user — catches fetchUser not returning the "
                          "user", "settings works — catches settings bugs", "testRefresh"]},
            {"what": "partial: names an area or condition but not the symptom",
             "examples": ["catches a bug in leap years",
                          "catches wrong handling of offline mode"]},
            {"what": "specific: names a user- or caller-visible symptom",
             "examples": ["catches shoppers billed twice for one order",
                          "catches the map staying blank after location access is granted"]}]},
}

AI_S1 = {
    "a_call_details": {"type": "noul", "instructions": {
        "question": "Does an entry in `assertions` check how many times, in what order, or with "
                    "which arguments the code called a collaborator, spy or helper?"},
        "criteria": {
            "true": {"what": "Asserts a call count, a call order, a call's arguments, or that a "
                             "method was called",
                     "examples": ["#expect(mock.methodsCalled == [\"connect\", \"send\"])",
                                  "#expect(api.requestCount == 2)",
                                  "#expect(queue.didCallFlush)"]},
            "false": {"what": "Asserts results the feature produces",
                      "not_for": ["the value the feature saves, sends or shows when that value is "
                                  "the feature's result",
                                  "TestStore send or receive with the state it produces",
                                  "advancing a test clock and checking what happened after the "
                                  "delay"]}}},
    "a_private_state": {"type": "noul", "instructions":
        "Does an entry in `assertions` read a private, underscored or testing-only property that "
        "callers of the code cannot see?",
        "criteria": {
            "true": "Reads a property like `_pendingQueue` or `_retainCountForTesting`, or other "
                    "internal bookkeeping.",
            "false": "Reads only public results, returned values, or TestStore state."}},
    "a_log_text": {"type": "noul", "instructions":
        "Does an entry in `assertions` compare the exact text of a log or debug message?"},
    "a_base_crit": {"type": "noul", "instructions": BASE_AI.replace("the test", "`test_source`"),
        "criteria": {
            "true": "Asserts private call order, call counts, internal or testing-only state, exact "
                    "log text, or which collaborator was called.",
            "false": {"what": "Asserts results a user or caller can observe",
                      "not_for": ["retry, backoff, debounce or timer tests that advance a test clock "
                                  "and check the resulting state",
                                  "TestStore send or receive with the state it produces"]}}},
}


def fib_choice(state):
    """Choice over the parsed assertions: which one checks a changed value, or none."""
    crit = {f"a{i}": a for i, a in enumerate(state["assertions"][:20])}
    crit["none"] = ("No assertion checks a value the changed lines in `code_under_test` compute "
                    "or set: each checks a value the test built, a value a test double returned, "
                    "an untouched field, or only existence.")
    return {"type": "choice", "instructions":
            "Which entry in `assertions` checks a value that the changed lines in "
            "`code_under_test` compute or set?", "criteria": crit}


def battery(kind, state):
    if kind == "s0":
        return {**BASELINE, **S0_DECOMP}
    qs = {**FIB_S1, **NAME_S1, **AI_S1}
    qs["f_which_assertion"] = fib_choice(state)
    return qs
