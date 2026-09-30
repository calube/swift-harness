"""Shared case loading, state building and Jev transport for the question-design study."""
import hashlib, json, os, re, time, urllib.request, urllib.error

# Data and outputs live one level up from this scripts/ directory.
P = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO_JUDGE = os.path.join(P, "..", "..", "..", "plugin", "gate", "Fixtures", "judge")
DEV = os.path.join(P, "dev-set")
HOLDOUT = os.path.join(P, "dev-holdout")
URL = "https://api.typesafe.ai/v1/systemone"
MODEL = "jev-1.13.0"
LEDGER = os.path.join(P, "ledger.jsonl")
BUDGET = 600

SUBJECT_DESCRIPTION = (
    "a Swift test function from an iOS app built with The Composable Architecture, and the "
    "production code change it covers")


def split_of(case_id):
    return "tune" if hashlib.sha256(case_id.encode()).digest()[0] < 0x55 else "report"


def load_cases():
    """Dev cases plus the repo's tune-split cases. Report-split cases are never opened."""
    out = []
    for root, name in ((DEV, "dev"), (HOLDOUT, "holdout")):
      if not os.path.exists(os.path.join(root, "labels.json")):
        continue
      for c in json.load(open(os.path.join(root, "labels.json")))["cases"]:
        d = os.path.join(root, "cases", c["id"])
        out.append(dict(set=name, id=c["id"], kind=c.get("kind"), declaredTier=c["declaredTier"],
                        expected=c["expected"],
                        source=open(os.path.join(d, "Test.swift.txt")).read(),
                        context=open(os.path.join(d, "Change.diff")).read()))
    labels = json.load(open(os.path.join(REPO_JUDGE, "labels.json")))
    for c in labels["cases"]:
        if split_of(c["id"]) != "tune":
            continue  # report split: neither the label nor the case is read
        d = os.path.join(REPO_JUDGE, "cases", c["id"])
        out.append(dict(set="tune", id=c["id"], kind=c.get("label"), declaredTier=c["declaredTier"],
                        expected=c["expected"],
                        source=open(os.path.join(d, "Test.swift.txt")).read(),
                        context=open(os.path.join(d, "Change.diff")).read()))
    return out


# ------------------------------------------------------------------ pre-parsing in code
def test_name(source):
    m = re.search(r'@Test\("((?:[^"\\]|\\.)*)"', source)
    if m:
        return m.group(1)
    m = re.search(r"func\s+(\w+)\s*\(", source)
    return m.group(1) if m else ""


def name_parts(name):
    parts = re.split(r"\s+[—–-]+\s+catches\s+", name, maxsplit=1)
    if len(parts) == 2:
        return {"behavior": parts[0], "catches": "catches " + parts[1]}
    return {"behavior": name, "catches": None}


def assertions(source):
    """Each assertion statement: #expect/#require/XCTAssert*, and TestStore send/receive with the
    trailing closure that asserts state, joined onto one line."""
    lines = source.split("\n")
    out, i = [], 0
    while i < len(lines):
        s = lines[i].strip()
        if re.match(r"(try\s+)?#(expect|require)\b|XCTAssert\w*\(|(try\s+)?XCTUnwrap", s):
            out.append(s)
        elif re.match(r"await\s+store\.(send|receive)\b", s):
            if s.endswith("{"):
                block, depth = [s], s.count("{") - s.count("}")
                while depth > 0 and i + 1 < len(lines):
                    i += 1
                    t = lines[i].strip()
                    block.append(t)
                    depth += t.count("{") - t.count("}")
                out.append(" ".join(block))
            else:
                out.append(s)
        i += 1
    return out


def state_s0(case):
    """Exactly what JevRequest.state sends today."""
    st = {"subject_kind": SUBJECT_DESCRIPTION, "subject": case["source"], "context": case["context"]}
    if case["declaredTier"]:
        st["declared_tier"] = case["declaredTier"]
    return st


def state_s1(case):
    """Named fields plus code-parsed name parts and assertions."""
    name = test_name(case["source"])
    return {
        "subject_kind": SUBJECT_DESCRIPTION,
        "test_name": dict(full=name, **name_parts(name)),
        "test_source": case["source"],
        "assertions": assertions(case["source"]),
        "code_under_test": case["context"],
        "declared_tier": case["declaredTier"],
    }


STATES = {"s0": state_s0, "s1": state_s1}


# ------------------------------------------------------------------ transport
def calls_used():
    if not os.path.exists(LEDGER):
        return 0
    return sum(1 for _ in open(LEDGER))


def ask(state, questions, key, tag):
    if calls_used() >= BUDGET:
        raise SystemExit("Jev call budget exhausted")
    body = {"model": MODEL, "state": state, "questions": questions}
    data = json.dumps(body, sort_keys=True).encode()
    req = urllib.request.Request(URL, data=data, method="POST", headers={
        "Authorization": "Bearer " + key, "Content-Type": "application/json"})
    t0 = time.time()
    status, reply, err = None, None, None
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                status, reply = resp.status, json.loads(resp.read())
            break
        except urllib.error.HTTPError as e:
            status = e.code
            err = e.read().decode(errors="replace").replace(key, "<key>")[:500]
        except Exception as e:
            err = repr(e).replace(key, "<key>")[:500]
        finally:
            with open(LEDGER, "a") as f:
                f.write(json.dumps({"tag": tag, "t": time.time(), "status": status}) + "\n")
        if status not in (429, 500, 502, 503, 520, None):
            break
        time.sleep(2 * (attempt + 1))
    return {"status": status, "latency_s": time.time() - t0, "reply": reply, "error": err,
            "request_bytes": len(data)}
