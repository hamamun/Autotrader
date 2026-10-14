#!/usr/bin/env python3
"""Mirror of the Autotrader session volume-profile walk, run on synthetic sessions.

The MQL5 cannot be compiled in this sandbox, so this script re-states the
value-area expansion of VolumeFlow.mqh (start at the POC, grow outward bin by
bin until 70% of the session volume is inside) and runs it over tens of
thousands of synthetic sessions - including the shapes that used to kill it.

Why this exists
---------------
14 Oct 2026, on some symbols only, the terminal logged:

    Autotrader (EURUSDm,M15)  array out of range in 'VolumeFlow.mqh' (200,38)

Line 200 was the "volume of the bin below the POC" read. Two faults sat in
that five-line loop, and either one alone explains the terminal line:

  1. the downward pointer did `dn++` instead of `dn--`. Incrementing it walked
     the low side back UP over the bins already counted. When the top of the
     session range held no volume (a spike with no business done up there) the
     up side was exhausted first, so every later step took the dn branch and
     dn climbed to ATVF_BINS = 24 - one past the end of `double bin[24]`.
     Whether a symbol hit that depended purely on its session profile: that is
     why "some symbols are fine" and others died.

  2. the range guard lived inside the `?:`:

         double bd = (dn >= 0) ? bin[dn] : -1.0;

     MQL5 bounds-checks both operands of a `?:` on a fixed-size array, so the
     read is not protected by its own guard: with the POC in the lowest bin
     (dn = -1) the check fires on the read the guard was meant to prevent.
     The fix reads each neighbour behind a plain `if`.

Both are modelled below, so the crash is reproduced rather than just
described; the patched loop is then run over the same sessions.

What is checked
---------------
  * old loop, lazy `?:`  -> sessions that read bin[24..]        (fault 1)
  * old loop, eager `?:` -> sessions that read bin[-1]          (fault 2)
  * patched loop         -> no out-of-range read is ever formed, no bin is
                            counted twice, the POC bin is always inside the
                            value area, VAH >= POC >= VAL, and the walk ends
                            at >= 70% of the volume or with both sides
                            exhausted.
"""
import math
import random

BINS = 24
SEED = 20261014
SESSIONS = 20000


def walk(bin_, buggy, eager_ternary):
    """Transcribe the loop line by line, as the terminal would run it.

    `buggy` picks the old dn++ behaviour; `eager_ternary` models MQL5
    evaluating both operands of `?:` (which is what makes bin[-1] reachable
    in the old code). The walk STOPS at the first out-of-range read, because
    that is what the terminal does: one message, then the EA is unloaded and
    everything downstream never happens.

    Returns (up, dn, acc, consumed, faults).
    """
    poc = 0
    for b in range(1, BINS):
        if bin_[b] > bin_[poc]:
            poc = b
    total = sum(bin_)
    acc = bin_[poc]
    consumed = [poc]
    up, dn = poc + 1, poc - 1
    faults = []

    while (up < BINS or dn >= 0) and total > 0.0 and acc < total * 0.70:
        # ---- line 199/200: neighbour volume, -1.0 when that side is finished
        if buggy:
            bu = -1.0
            if up < BINS:
                bu = bin_[up]
            elif eager_ternary:              # `?:` read bin[up] with up == BINS
                faults.append(("bin[up]", up))
                break
            bd = -1.0
            if dn >= 0:
                if dn >= BINS:               # guard is TRUE, so this always reads
                    faults.append(("bin[dn]", dn))
                    break
                bd = bin_[dn]
            elif eager_ternary:              # `?:` read bin[dn] with dn == -1
                faults.append(("bin[dn]", dn))
                break
        else:
            bu = -1.0
            if up < BINS:                    # plain if: the read sits INSIDE the guard
                assert 0 <= up < BINS
                bu = bin_[up]
            bd = -1.0
            if dn >= 0:
                assert 0 <= dn < BINS
                bd = bin_[dn]

        # ---- line 201/202: take the heavier side, walk that way
        if bu >= bd and up < BINS:
            acc += bu
            consumed.append(up)
            up += 1
        elif dn >= 0:
            acc += bd
            consumed.append(dn)
            if buggy:
                dn += 1                      # the old bug: walks back up
            else:
                dn -= 1                      # down is down
        else:
            break

    return up, dn, acc, consumed, faults


# ----------------------------------------------------------------- sessions
def random_session(rng):
    """A day of M15-ish bars: random-walk price, lognormal tick volume, the
    occasional news bar, an optional trend. Returns 24 bin volumes."""
    n_bars = rng.randint(40, 96)
    px = 1.1000
    drift = rng.choice([0.0, 0.0, 0.0, 0.3, -0.3, 0.8, -0.8])
    tps, vols = [], []
    for _ in range(n_bars):
        px += rng.gauss(drift * 0.00002, 0.00025)
        tps.append(px + rng.gauss(0.0, 0.00006))
        v = math.exp(rng.gauss(0.0, 0.9))
        if rng.random() < 0.10:
            v *= rng.uniform(3.0, 12.0)
        vols.append(v)
    lo, hi = min(tps), max(tps)
    if not hi > lo:
        return None
    step = (hi - lo) / BINS
    b = [0.0] * BINS
    for t, v in zip(tps, vols):
        i = min(max(int((t - lo) / step), 0), BINS - 1)
        b[i] += v
    return b


def spiky_session(rng):
    """The shape that crashed it: price spikes to a new high on a bar that does
    almost no business, so the top bins stay empty while the POC sits below."""
    low = [rng.uniform(0.5, 3.0) for _ in range(rng.randint(2, 10))]
    body = low + [rng.uniform(2.0, 6.0)]        # the POC bin, heavier than the low side
    return body + [0.0] * (BINS - len(body))


def main():
    print("session volume-profile walk (VolumeFlow.mqh value area)")
    print(f"  {SESSIONS} sessions, {BINS} price bins, 70% value area\n")

    # the adversarial shape, spelled out
    shape = [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 2.0] + [0.0] * 17
    o = walk(shape, buggy=True, eager_ternary=False)
    n = walk(shape, buggy=False, eager_ternary=False)
    print(f"  quiet day, one heavy bar, top of the range empty:")
    print(f"    bins  {[int(x) for x in shape[:7]]} + 17 empty")
    print(f"    old loop: {o[4]}  - dn reached {o[1]} while the array ends at {BINS}")
    print(f"    new loop: POC bin 6 -> value area bins {n[1] + 1}..{n[0] - 1}, "
          f"counted {sorted(set(n[3]))}, {100.0 * n[2] / sum(shape):.0f}% of volume\n")

    rng = random.Random(SEED)
    # per family: (sessions, faults), and the patched-loop counters
    fam = {"real": [0, 0], "spike": [0, 0]}
    old_neg, old_up, new = 0, 0, 0
    new_double, new_bracket, new_under70, walked_hard, checked = 0, 0, 0, 0, 0

    for k in range(SESSIONS):
        if k % 5 == 0:
            b, which = spiky_session(rng), "spike"
        else:
            b, which = random_session(rng), "real"
        if b is None:
            continue
        checked += 1
        total = sum(b)
        poc = max(range(BINS), key=lambda i: b[i])
        fam[which][0] += 1

        # --- what shipped on 14 Oct
        _, _, _, _, lazy = walk(b, buggy=True, eager_ternary=False)
        _, _, _, _, eager = walk(b, buggy=True, eager_ternary=True)
        fam[which][1] += 1 if any(t == "bin[dn]" and i >= BINS for t, i in lazy) else 0
        old_neg += 1 if any(i < 0 for _, i in eager) else 0
        old_up += 1 if any(t == "bin[up]" and i >= BINS for t, i in eager) else 0

        # --- what ships now
        up, dn, acc, consumed, faults = walk(b, buggy=False, eager_ternary=False)
        new += len(faults)
        if len(set(consumed)) != len(consumed):
            new_double += 1
        if not (0 <= dn + 1 <= poc <= up - 1 <= BINS - 1):
            new_bracket += 1
        if not (acc >= total * 0.70 - 1e-9 or (up >= BINS and dn < 0)):
            new_under70 += 1
        if b[poc] < total * 0.70 and min(b) == 0.0:
            walked_hard += 1          # sessions where the walk really had to work

    r_n, r_f = fam["real"]
    s_n, s_f = fam["spike"]
    print(f"  sessions simulated                     : {checked}")
    print( "  the 14 Oct loop read out of range on:")
    print(f"      realistic sessions                 : {r_f}/{r_n}"
          f"  ({100.0 * r_f / max(r_n, 1):.2f}%)   <- why only some symbols")
    print(f"      spike-shaped sessions              : {s_f}/{s_n}"
          f"  ({100.0 * s_f / max(s_n, 1):.1f}%)")
    print(f"      either family, POC in lowest bin   : {old_neg}"
          f"  ({100.0 * old_neg / checked:.2f}%)   <- the `?:` guard that is not one")
    print(f"      either family, up side at the top  : {old_up}"
          f"  ({100.0 * old_up / checked:.2f}%)   <- same class, eager `?:` only")
    print(f"  sessions the patched loop faults on    : {new}")
    print(f"  patched: a bin counted twice           : {new_double}")
    print(f"  patched: POC not inside [VAL, VAH]     : {new_bracket}")
    print(f"  patched: value area short of 70%       : {new_under70}")
    print(f"  (sessions where the walk had to cross empty bins: {walked_hard})")

    fails = []
    if checked < SESSIONS // 2:
        fails.append(f"only {checked} sessions were generated")
    if r_f == 0 and s_f == 0 and old_neg == 0:
        fails.append("the 14 Oct loop never failed - regression not reproduced")
    if new:
        fails.append(f"patched loop formed {new} out-of-range reads")
    if new_double:
        fails.append(f"patched loop counted a bin twice in {new_double} sessions")
    if new_bracket:
        fails.append(f"POC outside [VAL, VAH] in {new_bracket} sessions")
    if new_under70:
        fails.append(f"value area below 70% in {new_under70} sessions")

    print("\n" + ("ALL CHECKS PASSED" if not fails else f"FAILURES: {fails}"))
    return 1 if fails else 0


if __name__ == "__main__":
    raise SystemExit(main())
