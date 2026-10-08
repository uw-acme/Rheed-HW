#!/usr/bin/env python3
"""
Claude generated

Golden (reference) model for nms_top3, written from the spec in the top3.vhd
header -- NOT from the RTL -- so it can catch RTL bugs instead of copying them.

It writes two files for top3_testbench.sv:
    top3_frame.mem     1600 lines, one 16-bit hex value per line, raster order
                       (line k = pixel x = k % 40, y = k // 40)
    top3_expected.mem  9 lines, hex: val0 x0 y0  val1 x1 y1  val2 x2 y2
                       (unused ranks are 0 0 0)

Usage:
    python top3_golden.py --list               # show available tests
    python top3_golden.py single               # write files for one test
    python top3_golden.py random --seed 42     # random frame, reproducible
    python top3_golden.py --selftest           # check the model vs hand answers
"""

import argparse
import math
import os
import random

# ---------------------------------------------------------------------------
# Spec constants (must match the generics/constants in top3.vhd)
# ---------------------------------------------------------------------------
GRID_W, GRID_H = 40, 40
HALF = 2                # 5x5 window -> +/-2 around the centre
MIN_DIST_SQ = 64        # suppressed if dx^2 + dy^2 < 64 (closer than 8 px)
TOP_N = 3
MAX_VAL = 0xFFFF        # tdata is 16-bit unsigned


# ---------------------------------------------------------------------------
# The model
# ---------------------------------------------------------------------------
def find_candidates(grid):
    """
    PASS 1: every non-zero pixel that is the maximum of its 5x5 neighbourhood.

    grid[y][x] -- y is the row, x the column.
    Neighbours outside the grid are ignored (so border peaks survive).
    Tie-break: the centre must be STRICTLY greater than neighbours that come
    earlier in raster order, and >= neighbours that come later. So on a
    plateau, only the raster-first pixel survives.

    Returns a list of (val, x, y) in raster order -- the same order the RTL
    writes them into its candidate RAM.
    """
    cands = []
    for y in range(GRID_H):
        for x in range(GRID_W):
            v = grid[y][x]
            if v == 0:
                continue                         # zero is never a candidate
            is_max = True
            for dy in range(-HALF, HALF + 1):
                for dx in range(-HALF, HALF + 1):
                    if dx == 0 and dy == 0:
                        continue                 # the centre itself
                    nx, ny = x + dx, y + dy
                    if not (0 <= nx < GRID_W and 0 <= ny < GRID_H):
                        continue                 # off the grid: ignored
                    n = grid[ny][nx]
                    earlier = dy < 0 or (dy == 0 and dx < 0)
                    if earlier and not v > n:
                        is_max = False
                    if not earlier and not v >= n:
                        is_max = False
            if is_max:
                cands.append((v, x, y))
    return cands


def is_near(a, b):
    """True if two (val, x, y) peaks are closer than 8 px Euclidean."""
    dx, dy = a[1] - b[1], a[2] - b[2]
    return dx * dx + dy * dy < MIN_DIST_SQ


def greedy_nms(cands):
    """
    PASS 2: up to TOP_N sweeps. Each sweep picks the highest candidate that is
    not near any ALREADY-ACCEPTED peak. Ties go to the earlier candidate in
    raster order (strict '>' while scanning). Stops early if nothing is left.
    """
    accepted = []
    for _ in range(TOP_N):
        best = None
        for c in cands:                          # raster order
            if any(is_near(c, a) for a in accepted):
                continue
            if best is None or c[0] > best[0]:
                best = c
        if best is None:
            break
        accepted.append(best)
    while len(accepted) < TOP_N:
        accepted.append((0, 0, 0))               # unused slots read as zero
    return accepted


def golden(grid):
    return greedy_nms(find_candidates(grid))


# ---------------------------------------------------------------------------
# Test frames
# ---------------------------------------------------------------------------
def empty():
    return [[0] * GRID_W for _ in range(GRID_H)]


def frame(*peaks):
    """frame((val, x, y), ...) -> grid with only those pixels set."""
    g = empty()
    for v, x, y in peaks:
        g[y][x] = v
    return g


# name -> (description, grid, hand-derived expected answer)
# The expected answers were worked out by hand from the spec. --selftest
# checks the model against them, so the model is itself tested.
DIRECTED = {
    "zeros": (
        "all zeros: no candidates, done must still fire, outputs all 0",
        empty(),
        [(0, 0, 0), (0, 0, 0), (0, 0, 0)]),
    "single": (
        "one peak, asymmetric coords so an x/y swap is visible",
        frame((500, 5, 30)),
        [(500, 5, 30), (0, 0, 0), (0, 0, 0)]),
    "three_far": (
        "three far-apart peaks: checks descending sort",
        frame((900, 5, 30), (700, 30, 5), (800, 20, 20)),
        [(900, 5, 30), (800, 20, 20), (700, 30, 5)]),
    "corners": (
        "peaks on all four corners: border masking; top 3 of 4",
        frame((300, 0, 0), (200, 39, 0), (100, 0, 39), (400, 39, 39)),
        [(400, 39, 39), (300, 0, 0), (200, 39, 0)]),
    "close_pair": (
        "500 is inside 600's 5x5 window, so it is never even a candidate",
        frame((600, 10, 10), (500, 12, 11), (100, 30, 30)),
        [(600, 10, 10), (100, 30, 30), (0, 0, 0)]),
    "dist_boundary": (
        "A=1000; B at (+7,+3) d^2=58 suppressed; D at (+8,0) d^2=64 kept; "
        "C at (-7,+4) d^2=65 kept",
        frame((1000, 10, 10), (900, 17, 13), (850, 18, 10), (800, 3, 14)),
        [(1000, 10, 10), (850, 18, 10), (800, 3, 14)]),
    "chain": (
        "A-B-C 6 px apart: B suppressed by A, but C is 12 px from A and is "
        "NOT blocked by the suppressed B",
        frame((100, 10, 20), (90, 16, 20), (80, 22, 20)),
        [(100, 10, 20), (80, 22, 20), (0, 0, 0)]),
    "plateau": (
        "2x2 block of equal values: only the raster-first pixel survives",
        frame((500, 20, 20), (500, 21, 20), (500, 20, 21), (500, 21, 21)),
        [(500, 20, 20), (0, 0, 0), (0, 0, 0)]),
    "tie_far": (
        "two equal peaks far apart: raster-first (lower y) ranks first",
        frame((700, 5, 30), (700, 30, 5)),
        [(700, 30, 5), (700, 5, 30), (0, 0, 0)]),
    "many": (
        "six separated peaks: only the top three come out",
        frame((10, 3, 3), (60, 35, 3), (20, 20, 20),
              (50, 3, 35), (30, 35, 35), (40, 12, 28)),
        [(60, 35, 3), (50, 3, 35), (40, 12, 28)]),
}


def random_frame(rng, ties=False):
    """
    Blob-ish frame resembling FOLO output: a few gaussian bumps on a noisy
    floor. ties=True quantises values coarsely so plateaus and equal peaks
    show up often (exercises the tie-break rules).
    """
    g = empty()
    for _ in range(rng.randint(0, 8)):
        px, py = rng.randrange(GRID_W), rng.randrange(GRID_H)
        amp = rng.randint(100, 60000)
        sig = rng.uniform(0.6, 2.5)
        for y in range(max(0, py - 8), min(GRID_H, py + 9)):
            for x in range(max(0, px - 8), min(GRID_W, px + 9)):
                d2 = (x - px) ** 2 + (y - py) ** 2
                g[y][x] += amp * math.exp(-d2 / (2 * sig * sig))
    noise = rng.choice([0, 0, 20, 200])
    for y in range(GRID_H):
        for x in range(GRID_W):
            v = g[y][x] + (rng.uniform(0, noise) if noise else 0)
            v = int(min(MAX_VAL, v))
            if ties:
                v = (v // 2000) * 2000
            g[y][x] = v
    return g


# ---------------------------------------------------------------------------
# File output
# ---------------------------------------------------------------------------
def write_files(grid, expected, outdir):
    frame_path = os.path.join(outdir, "top3_frame.mem")
    exp_path = os.path.join(outdir, "top3_expected.mem")
    with open(frame_path, "w", newline="\n") as fh:
        for y in range(GRID_H):
            for x in range(GRID_W):
                fh.write(f"{grid[y][x]:04x}\n")       # hex, as $readmemh wants
    with open(exp_path, "w", newline="\n") as fh:
        for v, x, y in expected:
            fh.write(f"{v:04x}\n{x:04x}\n{y:04x}\n")  # coords in HEX too
    return frame_path, exp_path


def report(name, grid, expected):
    cands = find_candidates(grid)
    print(f"test: {name}   ({len(cands)} pass-1 candidates)")
    for rank, (v, x, y) in enumerate(expected):
        print(f"   rank {rank}: val={v:5d} (0x{v:04x})  x={x:2d}  y={y:2d}")


# ---------------------------------------------------------------------------
def selftest():
    bad = 0
    for name, (_, grid, hand) in DIRECTED.items():
        got = golden(grid)
        ok = got == hand
        bad += not ok
        print(f"  {'ok  ' if ok else 'FAIL'} {name}"
              + ("" if ok else f"\n       model={got}\n       hand ={hand}"))
    print("model agrees with all hand answers" if not bad
          else f"{bad} disagreement(s) -- fix the model or the hand answer")
    return bad == 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("test", nargs="?", help="directed test name, 'random' or 'random_ties'")
    ap.add_argument("--seed", type=int, default=None, help="seed for random tests")
    ap.add_argument("--outdir", default=os.path.dirname(os.path.abspath(__file__)))
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    if args.selftest:
        raise SystemExit(0 if selftest() else 1)
    if args.list or not args.test:
        for name, (desc, _, _) in DIRECTED.items():
            print(f"  {name:14s} {desc}")
        print(f"  {'random':14s} random blob frame (use --seed to reproduce)")
        print(f"  {'random_ties':14s} random frame with coarse values -> many ties")
        return

    if args.test in ("random", "random_ties"):
        seed = args.seed if args.seed is not None else random.randrange(2 ** 32)
        grid = random_frame(random.Random(seed), ties=args.test == "random_ties")
        name = f"{args.test} --seed {seed}"
    elif args.test in DIRECTED:
        grid = DIRECTED[args.test][1]
        name = args.test
    else:
        raise SystemExit(f"unknown test '{args.test}' (try --list)")

    expected = golden(grid)
    report(name, grid, expected)
    for p in write_files(grid, expected, args.outdir):
        print(f"   wrote {p}")


if __name__ == "__main__":
    main()
