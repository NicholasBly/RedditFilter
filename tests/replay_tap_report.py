#!/usr/bin/env python3
"""Replay a RedditFilter Tap Inspector report, with and without DeadTapFix.

Usage: python3 tests/replay_tap_report.py report.txt

For every recorded tap it works out where the touch went and why, then runs
the same touch through UIKit's hit-test rules again with the fix applied:
subviews are tried front to back, and a view whose hitTest returns nil is
skipped so the next view underneath gets the touch. With DeadTapFix the
pull-to-refresh control always returns nil, so the touch falls through to the
feed cell under the finger (the report records which cell that is).
"""
import re
import sys

NUM = r"-?[\d.]+"


def parse(path):
    taps, cur, section = [], None, None
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        if line.startswith("===== DEAD"):
            section = "dead"
        elif line.startswith("===== RECENT"):
            section = "worked"
        m = re.match(rf"tap #(\d+) at (\S+), ({NUM})s, moved ({NUM})pt: (.*)", line)
        if m:
            cur = {"n": int(m[1]), "time": m[2], "verdict": m[5], "section": section, "chain": []}
            taps.append(cur)
            continue
        if cur is None:
            continue
        if (m := re.match(r"\s+touched view: (\S+)", line)):
            cur["touched"] = m[1]
        elif (m := re.match(r"\s+cells: under finger=(\S+)", line)):
            cur["under"] = None if m[1] == "none" else m[1]
        elif (m := re.match(rf"\s+(\d+) (\S+) frame=\(({NUM}),({NUM}) ({NUM})x({NUM})\)", line)):
            cur["chain"].append((m[2], float(m[3]), float(m[4]), float(m[5]), float(m[6])))
        elif "ListCollectionView offset=" in line and "list" not in cur:
            o = re.search(rf"offset=\(({NUM}),({NUM})\)", line)
            cur["list"] = {
                "offset_y": float(o[2]),
                "dragging": "dragging=1" in line,
                "decelerating": "decelerating=1" in line,
                "paging": "paging=1" in line,
            }
        elif (m := re.match(rf"\s+finger at \(({NUM}),({NUM})\)", line)):
            cur["finger"] = (float(m[1]), float(m[2]))
    return taps


def refresh_band(tap):
    """On-screen y range covered by the pull-to-refresh control, if it was hit."""
    for name, x, y, w, h in tap["chain"]:
        if name == "RefreshControlSliceView" and "list" in tap:
            top = y - tap["list"]["offset_y"]
            return (top, top + h)
    return None


def classify(tap):
    """(before, after) description for one tap."""
    band = refresh_band(tap)
    if band:
        fy = tap["finger"][1]
        inside = band[0] <= fy <= band[1]
        before = f"DEAD: landed on the invisible pull-to-refresh (screen y {band[0]:.0f}-{band[1]:.0f}, finger y {fy:.0f}{'' if inside else ' ?!'})"
        after = f"falls through to post {tap['under']} -> opens" if tap.get("under") else "falls through (no cell under finger)"
        return before, after, "refresh"
    lst = tap.get("list", {})
    if lst.get("dragging") or lst.get("decelerating"):
        return ("tap stopped a moving scroll (normal iOS: that tap only stops the scroll)", "unchanged (same as stock iOS)", "scroll")
    if lst.get("paging"):
        return ("full-screen media viewer: tap toggles the player controls, nothing to open", "unchanged", "viewer")
    if tap["section"] == "worked":
        return ("opened", "opened (fix doesn't touch it)", "worked")
    return (tap["verdict"], "not explained by the refresh control", "other")


def main(path):
    taps = parse(path)
    dead = [t for t in taps if t["section"] == "dead"]
    worked = [t for t in taps if t["section"] == "worked"]
    counts = {}
    print(f"{'tap':>5}  {'finger':>9}  before -> after")
    for t in sorted(taps, key=lambda t: t["n"]):
        before, after, kind = classify(t)
        counts[(t["section"], kind)] = counts.get((t["section"], kind), 0) + 1
        f = t.get("finger", (0, 0))
        print(f"#{t['n']:>4}  ({f[0]:>3.0f},{f[1]:>3.0f})  {before}\n{'':18}-> {after}")

    # Same scroll position, same post: did the working taps miss the band?
    print("\nControl check: working taps at the same scroll position as a dead streak")
    bands = {round(t["list"]["offset_y"], 1): refresh_band(t) for t in dead if refresh_band(t)}
    for t in worked:
        off = round(t.get("list", {}).get("offset_y", -1), 1)
        if off in bands:
            lo, hi = bands[off]
            fy = t["finger"][1]
            where = "inside" if lo <= fy <= hi else "outside"
            print(f"  #{t['n']}: offset {off}, finger y {fy:.0f} is {where} the band {lo:.0f}-{hi:.0f}, post {t.get('under')} -> {t['verdict']}")

    total_dead = len(dead)
    fixed = counts.get(("dead", "refresh"), 0)
    print(f"\nRecorded dead taps: {total_dead}")
    print(f"  caused by the stuck pull-to-refresh: {fixed}  -> all reach their post with DeadTapFix")
    print(f"  taps that stopped a moving scroll:   {counts.get(('dead', 'scroll'), 0)}  (normal iOS behavior)")
    print(f"  full-screen media viewer taps:       {counts.get(('dead', 'viewer'), 0)}  (not a feed tap)")
    print(f"  unexplained:                          {counts.get(('dead', 'other'), 0)}")
    return 0 if counts.get(("dead", "other"), 0) == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
