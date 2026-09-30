#!/usr/bin/env python3
"""Usage: run_round.py <round-module> <run-tag> [state-kinds comma list]

Sends one request per (case, state kind) with every question of that kind, and writes
raw/<run-tag>/<state>/<case>.json. Skips files that already exist, so a rerun resumes.
The key comes from TYPESAFE_API_KEY and is never written.
"""
import importlib, json, os, sys
from concurrent.futures import ThreadPoolExecutor
import lib


def main():
    mod = importlib.import_module(sys.argv[1])
    tag = sys.argv[2]
    kinds = sys.argv[3].split(",") if len(sys.argv) > 3 else ["s0", "s1"]
    key = os.environ.get("TYPESAFE_API_KEY", "").strip()
    if not key:
        raise SystemExit("TYPESAFE_API_KEY missing")
    cases = lib.load_cases()
    jobs = []
    for kind in kinds:
        d = os.path.join(lib.P, "raw", tag, kind)
        os.makedirs(d, exist_ok=True)
        for c in cases:
            path = os.path.join(d, c["id"] + ".json")
            if not os.path.exists(path):
                jobs.append((kind, c, path))
    print(f"{len(jobs)} requests; {lib.calls_used()} used of {lib.BUDGET}", flush=True)
    if lib.calls_used() + len(jobs) > lib.BUDGET:
        raise SystemExit("would exceed budget")

    def run(job):
        kind, c, path = job
        state = lib.STATES[kind](c)
        qs = mod.battery(kind, state)
        r = lib.ask(state, qs, key, f"{tag}/{kind}/{c['id']}")
        r.update(case=c["id"], kind=kind, questions=qs)
        if r["status"] == 200:
            json.dump(r, open(path, "w"), indent=1)
        return c["id"], kind, r["status"], r["error"]

    with ThreadPoolExecutor(3) as pool:
        for cid, kind, status, err in pool.map(run, jobs):
            if status != 200:
                print("FAIL", kind, cid, status, err, flush=True)
    print(f"done; {lib.calls_used()} used", flush=True)


if __name__ == "__main__":
    main()
