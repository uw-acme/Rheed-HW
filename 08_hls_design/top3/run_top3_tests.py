#!/usr/bin/env python3
"""
Claude generated

Regression runner for nms_top3: builds the sim once, then for each test
writes the .mem files with top3_golden.py, runs xsim in batch mode, and
prints a pass/fail table.

Run it from a terminal where Vivado's tools are on PATH (after
settings64.bat, or in the Vivado Tcl Shell), from inside this folder:

    python run_top3_tests.py                  # build + all directed + 20 random + 20 random_ties
    python run_top3_tests.py --no-build       # skip xvhdl/xvlog/xelab (RTL/TB unchanged)
    python run_top3_tests.py --random 100     # more random frames of each kind
    python run_top3_tests.py --seed 1234      # reproduce an earlier random batch
    python run_top3_tests.py --only chain plateau
    python run_top3_tests.py --only random:987654   # one random frame by seed

Close any open xsim GUI first, or the build step can't replace xsimk.exe.
Logs for failing tests are saved under ./failures/.
"""

import argparse
import os
import random
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import top3_golden as g  # noqa: E402  (same folder)

SNAPSHOT = "top3_sim"
BUILD_STEPS = [
    "xvhdl top3.vhd",
    "xvlog -sv top3_testbench.sv",
    f"xelab top3_testbench -debug typical -s {SNAPSHOT}",
]
SIM_CMD = f"xsim {SNAPSHOT} -R"
SIM_TIMEOUT_S = 300


def sh(cmd):
    """Run a shell command in this folder; return (exit code, combined output).
    shell=True so Windows can run Vivado's .bat wrappers."""
    p = subprocess.run(cmd, shell=True, cwd=HERE, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       timeout=SIM_TIMEOUT_S)
    return p.returncode, p.stdout


def build():
    for cmd in BUILD_STEPS:
        print(f"build: {cmd}")
        rc, out = sh(cmd)
        if rc != 0 or "ERROR:" in out:
            print(out)
            sys.exit(f"build step failed: {cmd}")
    print()


def judge(out):
    """Decide pass/fail from xsim's output. Returns (passed, reason)."""
    if "TIMEOUT" in out:
        return False, "TIMEOUT (done never rose)"
    errors = [ln.strip() for ln in out.splitlines() if ln.startswith("Error:")]
    if errors:
        return False, errors[0] + (f"  (+{len(errors) - 1} more)" if len(errors) > 1 else "")
    if "ERROR:" in out or "FATAL" in out:
        return False, "simulator error, see log"
    if "Best value was" not in out:
        return False, "never reached the checks, see log"
    return True, ""


def test_list(args):
    """[(display name, grid)] for this run."""
    if args.only:
        tests = []
        for t in args.only:
            if t.startswith(("random:", "random_ties:")):
                kind, seed = t.split(":")
                grid = g.random_frame(random.Random(int(seed)), ties=kind == "random_ties")
                tests.append((f"{kind} --seed {seed}", grid))
            elif t in g.DIRECTED:
                tests.append((t, g.DIRECTED[t][1]))
            else:
                sys.exit(f"unknown test '{t}'")
        return tests

    tests = [(name, d[1]) for name, d in g.DIRECTED.items()]
    master = random.Random(args.seed)
    for kind in ("random", "random_ties"):
        for _ in range(args.random):
            s = master.randrange(2 ** 32)
            tests.append((f"{kind} --seed {s}",
                          g.random_frame(random.Random(s), ties=kind == "random_ties")))
    return tests


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--no-build", action="store_true")
    ap.add_argument("--random", type=int, default=20,
                    help="random frames of EACH kind (default 20)")
    ap.add_argument("--seed", type=int, default=None,
                    help="master seed for the random batch (printed if omitted)")
    ap.add_argument("--only", nargs="+", metavar="TEST",
                    help="run only these (directed names, or random:SEED / random_ties:SEED)")
    args = ap.parse_args()

    if args.seed is None:
        args.seed = random.randrange(2 ** 32)
    if not args.no_build:
        build()

    tests = test_list(args)
    if not args.only:
        print(f"master seed: {args.seed}   (rerun this exact batch with --seed {args.seed})\n")

    fail_dir = os.path.join(HERE, "failures")
    results = []
    t0 = time.time()
    for name, grid in tests:
        expected = g.golden(grid)
        g.write_files(grid, expected, HERE)
        try:
            _, out = sh(SIM_CMD)
        except subprocess.TimeoutExpired:
            out = "TIMEOUT (xsim process hung)"
        ok, why = judge(out)
        results.append((name, ok))
        print(f"  {'PASS' if ok else 'FAIL'}  {name:28s} {why}")
        if not ok:
            os.makedirs(fail_dir, exist_ok=True)
            fname = name.replace(" --seed ", "_") + ".log"
            with open(os.path.join(fail_dir, fname), "w") as fh:
                fh.write(f"expected: {expected}\n\n{out}")

    n_fail = sum(not ok for _, ok in results)
    print(f"\n{len(results) - n_fail}/{len(results)} passed "
          f"in {time.time() - t0:.0f}s"
          + (f"; failing logs in {fail_dir}" if n_fail else ""))
    if n_fail:
        print("reproduce one failure with:  python top3_golden.py <name> [--seed N]"
              "  then  xsim top3_sim -gui")
    sys.exit(1 if n_fail else 0)


if __name__ == "__main__":
    main()
