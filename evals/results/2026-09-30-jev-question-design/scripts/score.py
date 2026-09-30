#!/usr/bin/env python3
"""Scores every design over the answers in raw/<tag>/. Usage: score.py <tag> [designs-module]"""
import importlib, json, math, os, sys
import lib

POS = {"fails-if-broken": lambda e: e == "no", "name-specificity": lambda e: e == "vague",
       "asserts-implementation": lambda e: e == "yes"}


def wilson(k, n, z=1.96):
    if n == 0:
        return (float("nan"),) * 3
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return p, max(0, c - h), min(1, c + h)


def load(tag):
    """{case_id: {"s0": {qid: answer}, "s1": {...}}}"""
    out = {}
    for kind in ("s0", "s1"):
        d = os.path.join(lib.P, "raw", tag, kind)
        if not os.path.isdir(d):
            continue
        for f in os.listdir(d):
            r = json.load(open(os.path.join(d, f)))
            out.setdefault(r["case"], {})[kind] = r["reply"]["answers"]
    return out


def noul(a, kind, q):
    return a[kind][q]["noul"]


def prob(a, kind, q, opt):
    return a[kind][q]["probabilities"].get(opt, 0.0)


def load_claude():
    out = {}
    d = os.path.join(lib.P, "raw", "claude")
    for f in os.listdir(d) if os.path.isdir(d) else []:
        if f.startswith("_"):
            continue
        r = json.load(open(os.path.join(d, f)))
        if r.get("structured_output"):
            out[r["case"]] = r["structured_output"]
    return out


def metrics(rows):
    """rows: [(positive: bool, p_flag: float)]"""
    tp = sum(1 for y, p in rows if y and p >= 0.5)
    fp = sum(1 for y, p in rows if not y and p >= 0.5)
    fn = sum(1 for y, p in rows if y and p < 0.5)
    tn = sum(1 for y, p in rows if not y and p < 0.5)
    n = len(rows)
    brier = sum((p - (1 if y else 0)) ** 2 for y, p in rows) / n if n else float("nan")
    return dict(n=n, tp=tp, fp=fp, fn=fn, tn=tn, precision=wilson(tp, tp + fp),
                recall=wilson(tp, tp + fn), accuracy=wilson(tp + tn, n),
                specificity=wilson(tn, tn + fp), brier=brier)


def fmt(ci):
    p, lo, hi = ci
    return "  -  " if p != p else f"{p:.2f} [{lo:.2f},{hi:.2f}]"


def evaluate(tag, designs, only=None):
    ans = load(tag)
    cases = {c["id"]: c for c in lib.load_cases()}
    claude = load_claude()
    results = {}
    for q, ds in designs.items():
        for name, fn in ds.items():
            for split in ("dev", "holdout", "tune"):
                rows, per = [], {}
                for cid, a in ans.items():
                    c = cases[cid]
                    if c["set"] != split:
                        continue
                    try:
                        p = fn(a)
                    except KeyError:
                        continue
                    y = POS[q](c["expected"][q])
                    rows.append((y, p))
                    per[cid] = round(p, 3)
                if rows:
                    results[(q, name, split)] = dict(metrics(rows), per_case=per)
        # Claude on dev
        rows, per = [], {}
        for cid, so in claude.items():
            c = cases[cid]
            flag = {"fails-if-broken": "no", "name-specificity": "vague",
                    "asserts-implementation": "yes"}[q]
            d = so[q]
            s = sum(v for k, v in d.items() if k != "rationale")
            p = d[flag] / s
            rows.append((POS[q](c["expected"][q]), p))
            per[cid] = round(p, 3)
        if rows:
            results[(q, "claude-sonnet-5-5", "dev")] = dict(metrics(rows), per_case=per)
    return results


def print_table(results):
    last = None
    for (q, name, split), m in sorted(results.items(), key=lambda kv: (kv[0][0], kv[0][2], kv[0][1])):
        if (q, split) != last:
            print(f"\n## {q} [{split}]")
            print(f"{'design':<34} {'n':>3} {'TP/FP/FN/TN':>12}  {'recall':<18}{'precision':<18}"
                  f"{'accuracy':<18}brier")
            last = (q, split)
        print(f"{name:<34} {m['n']:>3} {m['tp']:>2}/{m['fp']}/{m['fn']}/{m['tn']:<4}  "
              f"{fmt(m['recall']):<18}{fmt(m['precision']):<18}{fmt(m['accuracy']):<18}"
              f"{m['brier']:.3f}")


if __name__ == "__main__":
    tag = sys.argv[1]
    mod = importlib.import_module(sys.argv[2] if len(sys.argv) > 2 else "designs")
    res = evaluate(tag, mod.DESIGNS)
    print_table(res)
    json.dump({"|".join(k): v for k, v in res.items()},
              open(os.path.join(lib.P, f"scores-{tag}.json"), "w"), indent=1)
