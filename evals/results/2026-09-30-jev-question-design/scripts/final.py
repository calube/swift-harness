#!/usr/bin/env python3
"""Final numbers for the shortlisted designs: mean over repeats r2 and r3, per-run counts, flips,
Claude on dev, and the Jev-first cascade. Writes results.json and prints markdown tables."""
import json, os
import lib, score, designs as D

RUNS = ["r2", "r3"]
SHORTLIST = {
    "fails-if-broken": ["base (s0, today)", "s0 NOT(calls AND asserts)", "s1 runs_changed v2",
                        "s1 checks_named", "s0 NOT runs OR NOT named", "s1 NOT runs OR NOT named"],
    "name-specificity": ["base (s0, today)", "probe criteria (s0)", "s1 structured score",
                         "s0 restates OR (no symptom, no cond)",
                         "s1 restates OR (no symptom, no cond)", "s1 choice adds=nothing"],
    "asserts-implementation": ["base (s0, today)", "s1 base+criteria",
                               "s0 any(call v2, private, log)", "s1 any(call v2, private, log)"],
}
WINNER = {"fails-if-broken": "s1 NOT runs OR NOT named",
          "name-specificity": "s1 choice adds=nothing",
          "asserts-implementation": "s1 any(call v2, private, log)"}
SETS = ["dev", "holdout", "tune"]
BANDS = [(0.3, 0.7), (0.2, 0.8), (0.1, 0.9)]


def main():
    cases = {c["id"]: c for c in lib.load_cases()}
    runs = {r: score.load(r) for r in RUNS}
    claude = score.load_claude()
    out = {"runs": RUNS, "jev_calls_used": lib.calls_used(), "questions": {}}
    for q, names in SHORTLIST.items():
        qo = out["questions"][q] = {}
        flagopt = {"fails-if-broken": "no", "name-specificity": "vague",
                   "asserts-implementation": "yes"}[q]
        for name in names:
            fn = D.DESIGNS[q][name]
            do = qo[name] = {}
            for s in SETS:
                per_run = {r: {cid: fn(a) for cid, a in runs[r].items() if cases[cid]["set"] == s}
                           for r in RUNS}
                ids = sorted(set.intersection(*(set(v) for v in per_run.values())))
                mean = {cid: sum(per_run[r][cid] for r in RUNS) / len(RUNS) for cid in ids}
                rows = [(score.POS[q](cases[cid]["expected"][q]), mean[cid]) for cid in ids]
                m = score.metrics(rows)
                m["per_run"] = {r: {k: v for k, v in score.metrics(
                    [(score.POS[q](cases[c]["expected"][q]), per_run[r][c]) for c in ids]).items()
                    if k in ("tp", "fp", "fn", "tn")} for r in RUNS}
                m["flips"] = sum(1 for c in ids if len({per_run[r][c] >= .5 for r in RUNS}) > 1)
                m["per_case"] = {c: round(mean[c], 3) for c in ids}
                do[s] = m
        # Claude on dev (one run)
        rows, per = [], {}
        for cid, so in claude.items():
            d = so[q]
            p = d[flagopt] / sum(v for k, v in d.items() if k != "rationale")
            rows.append((score.POS[q](cases[cid]["expected"][q]), p))
            per[cid] = round(p, 3)
        qo["claude-sonnet-5-5"] = {"dev": dict(score.metrics(rows), per_case=per)}
        # Cascade on the winner
        win = qo[WINNER[q]]
        casc = qo["cascade"] = {}
        for lo, hi in BANDS:
            key = f"{lo}-{hi}"
            casc[key] = {}
            for s in SETS:
                pc = win[s]["per_case"]
                esc = [c for c, p in pc.items() if lo < p < hi]
                kept = [c for c in pc if c not in esc]
                acc_kept = score.wilson(sum(1 for c in kept if (pc[c] >= .5) ==
                                            score.POS[q](cases[c]["expected"][q])), len(kept))
                entry = {"n": len(pc), "escalated": len(esc), "escalated_ids": esc,
                         "share": score.wilson(len(esc), len(pc)), "jev_kept_accuracy": acc_kept}
                if s == "dev":
                    both = [c for c in pc if c in claude or c in kept]
                    rows = []
                    for c in both:
                        p = pc[c] if c in kept else qo["claude-sonnet-5-5"]["dev"]["per_case"][c]
                        rows.append((score.POS[q](cases[c]["expected"][q]), p))
                    entry["combined"] = {k: v for k, v in score.metrics(rows).items()}
                casc[key][s] = entry
    json.dump(out, open(os.path.join(lib.P, "results.json"), "w"), indent=1)

    f = score.fmt
    for q, qo in out["questions"].items():
        print(f"\n### {q}\n")
        print("| design | set | n | TP/FP/FN/TN | recall | precision | accuracy | Brier | flips r2/r3 |")
        print("|---|---|---|---|---|---|---|---|---|")
        for name, do in qo.items():
            if name == "cascade":
                continue
            for s, m in do.items():
                print(f"| {name} | {s} | {m['n']} | {m['tp']}/{m['fp']}/{m['fn']}/{m['tn']} | "
                      f"{f(m['recall'])} | {f(m['precision'])} | {f(m['accuracy'])} | "
                      f"{m['brier']:.3f} | {m.get('flips', '-')} |")
        print(f"\ncascade on `{WINNER[q]}`:\n")
        print("| band | set | escalated | share | Jev-kept accuracy | combined (dev, Claude on escalated) |")
        print("|---|---|---|---|---|---|")
        for band, bs in qo["cascade"].items():
            for s, e in bs.items():
                comb = e.get("combined")
                cs = (f"{comb['tp']}/{comb['fp']}/{comb['fn']}/{comb['tn']} acc {f(comb['accuracy'])}"
                      if comb else "-")
                print(f"| {band} | {s} | {e['escalated']}/{e['n']} | {f(e['share'])} | "
                      f"{f(e['jev_kept_accuracy'])} | {cs} |")
    print("\nJev calls used:", out["jev_calls_used"])


if __name__ == "__main__":
    main()
