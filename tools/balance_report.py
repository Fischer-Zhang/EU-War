#!/usr/bin/env python3
"""Static scenario balance report for Eu-War (no Godot, no simulation).

For every scenario it aggregates each faction's force into a rough power score,
reports the force ratio, role coverage and terrain mix, and writes a markdown
report. Doubles as a CI gate: with --check it exits non-zero only on structural
or EXTREME problems (a faction with no units, no player faction, or a force
ratio beyond a hard band) — not on ordinary tuning differences.

Usage:
  balance_report.py            # print report to stdout + run checks
  balance_report.py --write    # also write docs/progress/balance_report.md
  balance_report.py --check    # checks only (quiet), exit code = gate result
"""
from __future__ import annotations
import glob
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "data")
OUT = os.path.join(ROOT, "docs", "progress", "balance_report.md")

# Force-ratio bands (player_power / enemy_power).
WARN_LOW, WARN_HIGH = 0.6, 1.7      # flagged as a note
FAIL_LOW, FAIL_HIGH = 0.33, 3.0     # hard gate (extreme imbalance)

ROLE = {
    "pikemen": "pike", "men_at_arms": "heavy_foot",
    "longbowmen": "missile", "crossbowmen": "missile",
    "arquebusiers": "shot", "musketeers": "shot",
    "light_cavalry": "light_horse", "heavy_cavalry": "shock_horse",
    "dragoons": "mounted", "field_cannon": "artillery", "mortar": "artillery",
    "pioneers": "engineer",
}


def load(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def unit_power(u: dict) -> float:
    # Rough single-unit combat value for relative comparison.
    return (
        u.get("attack", 0)
        + 0.5 * u.get("vs_armor", 0)
        + 0.6 * u.get("defense", 0)
        + 0.25 * u.get("hp", 0)
        + 1.5 * u.get("range", 1)
        + 0.2 * u.get("move", 0)
    )


def main() -> int:
    args = set(sys.argv[1:])
    check_only = "--check" in args
    write = "--write" in args

    units = load(os.path.join(DATA, "units.json"))
    scen_dir = os.path.join(DATA, "scenarios")
    files = sorted(glob.glob(os.path.join(scen_dir, "*.json")))

    errors, notes, lines = [], [], []
    lines.append("# Eu-War scenario balance report")
    lines.append("")
    lines.append("Static force comparison (power heuristic; no simulation). "
                 "Ratio = player power / enemy power.")
    lines.append("")
    lines.append("| scenario | player | ratio | player pow | enemy pow | player roles |")
    lines.append("|---|---|--:|--:|--:|---|")

    for fn in files:
        s = load(fn)
        sid = s.get("id", os.path.basename(fn))
        factions = {f["id"]: f for f in s.get("factions", [])}
        player = next((fid for fid, f in factions.items() if f.get("controller") == "player"), "")
        if player == "":
            errors.append(f"{sid}: no player-controlled faction")
            continue
        pow_by, cnt_by, roles_by = {}, {}, {}
        for u in s.get("units", []):
            fid = u.get("faction", "")
            t = u.get("type", "")
            pow_by[fid] = pow_by.get(fid, 0.0) + unit_power(units.get(t, {}))
            cnt_by[fid] = cnt_by.get(fid, 0) + 1
            roles_by.setdefault(fid, set()).add(ROLE.get(t, "?"))
        enemy_pow = sum(p for fid, p in pow_by.items() if fid != player)
        player_pow = pow_by.get(player, 0.0)
        for fid in factions:
            if cnt_by.get(fid, 0) == 0:
                errors.append(f"{sid}: faction '{fid}' has no units")
        ratio = (player_pow / enemy_pow) if enemy_pow > 0 else 0.0
        if enemy_pow > 0 and not (FAIL_LOW <= ratio <= FAIL_HIGH):
            errors.append(f"{sid}: extreme force ratio {ratio:.2f} (player {player_pow:.0f} vs enemy {enemy_pow:.0f})")
        elif enemy_pow > 0 and not (WARN_LOW <= ratio <= WARN_HIGH):
            notes.append(f"{sid}: force ratio {ratio:.2f} outside [{WARN_LOW}, {WARN_HIGH}]")
        roles = ",".join(sorted(roles_by.get(player, set())))
        lines.append(f"| {sid} | {player} | {ratio:.2f} | {player_pow:.0f} | {enemy_pow:.0f} | {roles} |")

    lines.append("")
    if notes:
        lines.append("## Notes (moderate imbalance)")
        lines += [f"- {n}" for n in notes]
        lines.append("")

    report = "\n".join(lines) + "\n"
    if write:
        os.makedirs(os.path.dirname(OUT), exist_ok=True)
        with open(OUT, "w", encoding="utf-8") as fh:
            fh.write(report)
    if not check_only:
        print(report)

    if errors:
        print("BALANCE GATE FAILED:", file=sys.stderr)
        for e in errors:
            print("  -", e, file=sys.stderr)
        return 1
    if check_only:
        print("balance: OK (%d scenarios, %d notes)" % (len(files), len(notes)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
