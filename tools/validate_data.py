#!/usr/bin/env python3
"""Static data validator for Eu-War — no Godot required.

Checks JSON parses, scenario references resolve against the catalogs, maps are
rectangular, unit placements are on-map and passable with no duplicate hexes,
victory targets are in-bounds, and commander applies_to lists are valid.
Exits non-zero on any error.
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "data")


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def offset_to_axial(col, row):
    return (col - (row >> 1), row)


def main():
    errors = []

    units = load(os.path.join(DATA, "units.json"))
    terrains = load(os.path.join(DATA, "terrains.json"))
    generals = load(os.path.join(DATA, "generals.json"))
    impassable = {k for k, v in terrains.items() if v.get("impassable")}

    # Required numeric fields per unit.
    for uid, u in units.items():
        for field in ("hp", "attack", "defense", "range", "move", "vision"):
            if not isinstance(u.get(field), int):
                errors.append(f"unit {uid}: missing/invalid int field '{field}'")
        if u.get("hp", 0) <= 0:
            errors.append(f"unit {uid}: hp must be > 0")

    # Commander applies_to must reference real units.
    for gid, g in generals.items():
        for t in g.get("applies_to", []):
            if t not in units:
                errors.append(f"commander {gid}: applies_to unknown unit '{t}'")

    scen_dir = os.path.join(DATA, "scenarios")
    scenario_files = sorted(f for f in os.listdir(scen_dir) if f.endswith(".json"))
    if len(scenario_files) < 5:
        errors.append(f"expected >= 5 scenarios, found {len(scenario_files)}")

    # Tech tree (optional): prerequisites and applies_to must resolve.
    techs_path = os.path.join(DATA, "techs.json")
    techs = load(techs_path) if os.path.exists(techs_path) else {}
    valid_mod_keys = {"attack", "defense", "vs_armor", "move", "vision"}
    for tid, t in techs.items():
        if not isinstance(t.get("cost"), int) or t.get("cost", 0) < 0:
            errors.append(f"tech {tid}: missing/invalid non-negative int 'cost'")
        for req in t.get("requires", []):
            if req not in techs:
                errors.append(f"tech {tid}: requires unknown tech '{req}'")
        applies = t.get("applies_to", "all")
        if applies != "all":
            if not isinstance(applies, list):
                errors.append(f"tech {tid}: applies_to must be \"all\" or a list")
            else:
                for ut in applies:
                    if ut not in units:
                        errors.append(f"tech {tid}: applies_to unknown unit '{ut}'")
        for k in t.get("mods", {}):
            if k not in valid_mod_keys:
                errors.append(f"tech {tid}: unknown mod key '{k}'")

    scenario_ids = {load(os.path.join(scen_dir, fn)).get("id") for fn in scenario_files}
    campaigns_path = os.path.join(DATA, "campaigns.json")
    campaigns = load(campaigns_path) if os.path.exists(campaigns_path) else {}
    for cid, c in campaigns.items():
        scens = c.get("scenarios", [])
        if not scens:
            errors.append(f"campaign {cid}: empty scenario list")
        for sid in scens:
            if sid not in scenario_ids:
                errors.append(f"campaign {cid}: unknown scenario '{sid}'")

    # Conquest (optional): territories, adjacency, and per-territory scenarios.
    conquest_path = os.path.join(DATA, "conquest.json")
    conquests = load(conquest_path) if os.path.exists(conquest_path) else {}
    for qid, q in conquests.items():
        terrs = q.get("territories", [])
        ids = {t.get("id") for t in terrs}
        if not any(t.get("owner") == "player" for t in terrs):
            errors.append(f"conquest {qid}: no player-owned starting territory")
        if not any(t.get("owner") == "enemy" for t in terrs):
            errors.append(f"conquest {qid}: no enemy territory to conquer")
        for t in terrs:
            sid = t.get("scenario", "")
            if sid and sid not in scenario_ids:
                errors.append(f"conquest {qid}: territory '{t.get('id')}' unknown scenario '{sid}'")
            if t.get("owner") == "enemy" and not sid:
                errors.append(f"conquest {qid}: enemy territory '{t.get('id')}' needs a scenario")
            for nb in t.get("links", []):
                if nb not in ids:
                    errors.append(f"conquest {qid}: territory '{t.get('id')}' links unknown '{nb}'")

    for fn in scenario_files:
        s = load(os.path.join(scen_dir, fn))
        sid = s.get("id", fn)
        m = s.get("map", {})
        rows = m.get("tiles", [])
        w, h = m.get("width"), m.get("height")
        if len(rows) != h:
            errors.append(f"{sid}: map height {h} != rows {len(rows)}")
        for r, row in enumerate(rows):
            if len(row) != w:
                errors.append(f"{sid}: row {r} width {len(row)} != {w}")
            for c, t in enumerate(row):
                if t not in terrains:
                    errors.append(f"{sid}: unknown terrain '{t}' at [{c},{r}]")

        faction_ids = {f.get("id") for f in s.get("factions", [])}
        controllers = [f.get("controller") for f in s.get("factions", [])]
        if "player" not in controllers:
            errors.append(f"{sid}: no player-controlled faction")

        seen = {}
        for u in s.get("units", []):
            t = u.get("type")
            if t not in units:
                errors.append(f"{sid}: unknown unit type '{t}'")
            if u.get("faction") not in faction_ids:
                errors.append(f"{sid}: unit in unknown faction '{u.get('faction')}'")
            gid = u.get("general", "")
            if gid and gid not in generals:
                errors.append(f"{sid}: unknown commander '{gid}'")
            col, row = u.get("at", [0, 0])
            if not (0 <= row < (h or 0) and 0 <= col < (w or 0)):
                errors.append(f"{sid}: unit '{u.get('name')}' off-map at {u.get('at')}")
                continue
            terr = rows[row][col]
            if terr in impassable:
                errors.append(f"{sid}: unit '{u.get('name')}' on impassable {terr} at {u.get('at')}")
            key = (col, row)
            if key in seen:
                errors.append(f"{sid}: duplicate coord {u.get('at')} ({u.get('name')} & {seen[key]})")
            seen[key] = u.get("name")

        # Deployment zones (optional): faction must exist, rect in bounds.
        for fid, cfg in s.get("deployment", {}).items():
            if fid not in faction_ids:
                errors.append(f"{sid}: deployment for unknown faction '{fid}'")
            cols = cfg.get("cols", [0, 0])
            rows = cfg.get("rows", [0, 0])
            if not (len(cols) == 2 and len(rows) == 2):
                errors.append(f"{sid}: deployment {fid} needs 'cols' and 'rows' pairs")
                continue
            if not (0 <= cols[0] <= cols[1] < (w or 0)):
                errors.append(f"{sid}: deployment {fid} cols {cols} out of bounds")
            if not (0 <= rows[0] <= rows[1] < (h or 0)):
                errors.append(f"{sid}: deployment {fid} rows {rows} out of bounds")

        # Victory targets in bounds.
        for fid, cond in s.get("victory", {}).items():
            if cond.get("type") == "capture":
                col, row = cond.get("target", [0, 0])
                if not (0 <= row < (h or 0) and 0 <= col < (w or 0)):
                    errors.append(f"{sid}: {fid} capture target off-map {cond.get('target')}")

    if errors:
        print("DATA VALIDATION FAILED:")
        for e in errors:
            print("  -", e)
        return 1
    print(f"data OK: {len(units)} units, {len(terrains)} terrains, "
          f"{len(generals)} commanders, {len(scenario_files)} scenarios")
    return 0


if __name__ == "__main__":
    sys.exit(main())
