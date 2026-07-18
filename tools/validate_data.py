#!/usr/bin/env python3
"""Static data validator for Eu-War — no Godot required.

Checks JSON parses, scenario references resolve against the catalogs, maps are
rectangular, unit placements are on-map and passable with no duplicate hexes,
victory conditions match the engine contract, conquest maps are coherent, and
commander applies_to lists are valid.
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


def coord_pair(value):
    if not isinstance(value, list) or len(value) < 2:
        return None
    if not isinstance(value[0], int) or not isinstance(value[1], int):
        return None
    return (value[0], value[1])


def coord_in_bounds(coord, width, height):
    if coord is None:
        return False
    col, row = coord
    return 0 <= row < (height or 0) and 0 <= col < (width or 0)


def tile_at(rows, coord):
    if coord is None:
        return None
    col, row = coord
    if row < 0 or row >= len(rows):
        return None
    if col < 0 or col >= len(rows[row]):
        return None
    return rows[row][col]


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

    scenario_entries = []
    scenario_id_counts = {}
    for fn in scenario_files:
        s = load(os.path.join(scen_dir, fn))
        sid = s.get("id", "")
        scenario_entries.append((fn, sid, s))
        if not isinstance(sid, str) or sid == "":
            errors.append(f"{fn}: missing/invalid scenario id")
            continue
        scenario_id_counts[sid] = scenario_id_counts.get(sid, 0) + 1
    for sid, count in scenario_id_counts.items():
        if count > 1:
            errors.append(f"duplicate scenario id '{sid}' appears {count} times")
    scenario_ids = set(scenario_id_counts.keys())

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

    campaigns_path = os.path.join(DATA, "campaigns.json")
    campaigns = load(campaigns_path) if os.path.exists(campaigns_path) else {}
    for cid, c in campaigns.items():
        scens = c.get("scenarios", [])
        if not scens:
            errors.append(f"campaign {cid}: empty scenario list")
        if len(scens) != len(set(scens)):
            errors.append(f"campaign {cid}: duplicate scenario entries")
        for sid in scens:
            if sid not in scenario_ids:
                errors.append(f"campaign {cid}: unknown scenario '{sid}'")

    # The grand campaign is the complete chronological tour. Keep this contract
    # data-driven so every newly added historical scenario must be integrated.
    grand_scens = campaigns.get("grand_campaign", {}).get("scenarios", [])
    historical_ids = scenario_ids - {"00_tutorial", "10_sandbox"}
    grand_ids = set(grand_scens)
    missing_grand = sorted(historical_ids - grand_ids)
    extra_grand = sorted(grand_ids - historical_ids)
    if missing_grand:
        errors.append(f"campaign grand_campaign: missing historical scenarios {missing_grand}")
    if extra_grand:
        errors.append(f"campaign grand_campaign: non-historical scenarios {extra_grand}")
    previous_year = 0
    for sid in grand_scens:
        year_text = sid.rsplit("_", 1)[-1]
        if not year_text.isdigit():
            errors.append(f"campaign grand_campaign: scenario '{sid}' has no trailing year")
            continue
        year = int(year_text)
        if year < previous_year:
            errors.append(
                f"campaign grand_campaign: '{sid}' ({year}) is out of chronological order"
            )
        previous_year = year

    # Conquest (optional): territories, adjacency, and per-territory scenarios.
    conquest_path = os.path.join(DATA, "conquest.json")
    conquests = load(conquest_path) if os.path.exists(conquest_path) else {}
    for qid, q in conquests.items():
        terrs = q.get("territories", [])
        id_counts = {}
        for t in terrs:
            tid = t.get("id", "")
            if not isinstance(tid, str) or tid == "":
                errors.append(f"conquest {qid}: territory missing/invalid id")
                continue
            id_counts[tid] = id_counts.get(tid, 0) + 1
        for tid, count in id_counts.items():
            if count > 1:
                errors.append(f"conquest {qid}: duplicate territory id '{tid}'")
        ids = set(id_counts.keys())
        terr_by_id = {t.get("id"): t for t in terrs if t.get("id") in ids}
        neighbors_by_id = {tid: set() for tid in ids}
        # Multi-faction powers: exactly one player-controlled power; every
        # territory owner references a defined power id (or "neutral").
        powers = q.get("powers", [])
        power_ids = set()
        player_powers = []
        for p in powers:
            pid = p.get("id", "")
            if not isinstance(pid, str) or pid == "":
                errors.append(f"conquest {qid}: power missing/invalid id")
                continue
            power_ids.add(pid)
            if p.get("controller") == "player":
                player_powers.append(pid)
        if powers and len(player_powers) != 1:
            errors.append(f"conquest {qid}: needs exactly one player-controlled power (found {len(player_powers)})")
        player_id = player_powers[0] if player_powers else "player"
        valid_owners = power_ids | {"neutral"}
        if not any(t.get("owner") == player_id for t in terrs):
            errors.append(f"conquest {qid}: no territory owned by the player power '{player_id}'")
        if not any(t.get("owner") not in (player_id, "neutral") for t in terrs):
            errors.append(f"conquest {qid}: no rival-power territory to conquer")
        for t in terrs:
            tid = t.get("id")
            sid = t.get("scenario", "")
            owner = t.get("owner", "neutral")
            ttype = t.get("type", "city")
            if powers and owner not in valid_owners:
                errors.append(f"conquest {qid}: territory '{tid}' owner '{owner}' is not a defined power")
            if ttype not in ("city", "resource"):
                errors.append(f"conquest {qid}: territory '{tid}' invalid type '{ttype}'")
            if sid and sid not in scenario_ids:
                errors.append(f"conquest {qid}: territory '{tid}' unknown scenario '{sid}'")
            # A rival-power territory must be conquerable (needs a battle scenario).
            if owner not in (player_id, "neutral") and not sid:
                errors.append(f"conquest {qid}: rival territory '{tid}' needs a scenario")
            for nb in t.get("links", []):
                if nb not in ids:
                    errors.append(f"conquest {qid}: territory '{tid}' links unknown '{nb}'")
                elif tid in ids:
                    neighbors_by_id[tid].add(nb)
                    neighbors_by_id[nb].add(tid)
        if ids:
            start = next(iter(ids))
            visited = {start}
            stack = [start]
            while stack:
                cur = stack.pop()
                for nb in neighbors_by_id.get(cur, set()):
                    if nb not in visited:
                        visited.add(nb)
                        stack.append(nb)
            if len(visited) != len(ids):
                missing = sorted(ids - visited)
                errors.append(f"conquest {qid}: disconnected territories {missing}")

    victory_types = {"eliminate", "capture", "survive", "control_count"}
    for fn, file_sid, s in scenario_entries:
        sid = file_sid if isinstance(file_sid, str) and file_sid else fn
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
            coord = coord_pair(u.get("at", [0, 0]))
            if not coord_in_bounds(coord, w, h):
                errors.append(f"{sid}: unit '{u.get('name')}' off-map at {u.get('at')}")
                continue
            col, row = coord
            terr = tile_at(rows, coord)
            if terr is None:
                errors.append(f"{sid}: unit '{u.get('name')}' off-map at {u.get('at')}")
                continue
            if terr in impassable:
                errors.append(f"{sid}: unit '{u.get('name')}' on impassable {terr} at {u.get('at')}")
            key = (col, row)
            if key in seen:
                errors.append(f"{sid}: duplicate coord {u.get('at')} ({u.get('name')} & {seen[key]})")
            seen[key] = u.get("name")

        # Reinforcements (optional): scheduled spawns, same shape as units.
        for r in s.get("reinforcements", []):
            if r.get("type") not in units:
                errors.append(f"{sid}: reinforcement unknown unit '{r.get('type')}'")
            if r.get("faction") not in faction_ids:
                errors.append(f"{sid}: reinforcement in unknown faction '{r.get('faction')}'")
            if not isinstance(r.get("at_turn"), int) or r.get("at_turn", 0) < 1:
                errors.append(f"{sid}: reinforcement '{r.get('name')}' needs at_turn >= 1")
            coord = coord_pair(r.get("at", [0, 0]))
            if not coord_in_bounds(coord, w, h):
                errors.append(f"{sid}: reinforcement '{r.get('name')}' off-map at {r.get('at')}")
            else:
                terr = tile_at(rows, coord)
                if terr is None:
                    errors.append(f"{sid}: reinforcement '{r.get('name')}' off-map at {r.get('at')}")
                elif terr in impassable:
                    errors.append(f"{sid}: reinforcement '{r.get('name')}' on impassable {terr}")

        # Secondary objectives (optional).
        sec_types = {"no_losses", "by_turn", "hold_hex", "eliminate_type"}
        for o in s.get("secondary_objectives", []):
            ot = o.get("type", "")
            if ot not in sec_types:
                errors.append(f"{sid}: secondary objective unknown type '{ot}'")
            if ot == "by_turn" and not isinstance(o.get("turn"), int):
                errors.append(f"{sid}: by_turn objective '{o.get('id')}' needs int 'turn'")
            if ot == "eliminate_type" and o.get("unit_type") not in units:
                errors.append(f"{sid}: eliminate_type objective '{o.get('id')}' unknown unit '{o.get('unit_type')}'")
            if ot == "hold_hex":
                coord = coord_pair(o.get("at", [0, 0]))
                if not coord_in_bounds(coord, w, h):
                    errors.append(f"{sid}: hold_hex objective '{o.get('id')}' off-map {o.get('at')}")

        # Deployment zones (optional): faction must exist, rect in bounds.
        for fid, cfg in s.get("deployment", {}).items():
            if fid not in faction_ids:
                errors.append(f"{sid}: deployment for unknown faction '{fid}'")
            cols = cfg.get("cols", [0, 0])
            dep_rows = cfg.get("rows", [0, 0])
            if not (len(cols) == 2 and len(dep_rows) == 2):
                errors.append(f"{sid}: deployment {fid} needs 'cols' and 'rows' pairs")
                continue
            if not (0 <= cols[0] <= cols[1] < (w or 0)):
                errors.append(f"{sid}: deployment {fid} cols {cols} out of bounds")
            if not (0 <= dep_rows[0] <= dep_rows[1] < (h or 0)):
                errors.append(f"{sid}: deployment {fid} rows {dep_rows} out of bounds")

        # Victory conditions must match VictoryChecker's supported contract.
        victory = s.get("victory", {})
        if not isinstance(victory, dict) or not victory:
            errors.append(f"{sid}: missing/invalid victory conditions")
        for fid, cond in victory.items():
            if fid not in faction_ids:
                errors.append(f"{sid}: victory for unknown faction '{fid}'")
            if not isinstance(cond, dict):
                errors.append(f"{sid}: victory for {fid} must be an object")
                continue
            cond_type = cond.get("type", "eliminate")
            if cond_type not in victory_types:
                errors.append(f"{sid}: {fid} victory unknown type '{cond_type}'")
                continue
            if "by_turn" in cond and (not isinstance(cond.get("by_turn"), int) or cond.get("by_turn", 0) < 1):
                errors.append(f"{sid}: {fid} victory by_turn must be >= 1")
            if cond_type == "capture":
                target = coord_pair(cond.get("target", []))
                if not coord_in_bounds(target, w, h):
                    errors.append(f"{sid}: {fid} capture target off-map {cond.get('target')}")
                else:
                    terr = tile_at(rows, target)
                    if terr is None:
                        errors.append(f"{sid}: {fid} capture target off-map {cond.get('target')}")
                    elif terr in impassable:
                        errors.append(f"{sid}: {fid} capture target on impassable {terr}")
            if cond_type == "control_count":
                targets = cond.get("targets", [])
                if not isinstance(targets, list) or not targets:
                    errors.append(f"{sid}: {fid} control_count needs non-empty targets")
                    targets = []
                required = cond.get("required", len(targets))
                if not isinstance(required, int) or required < 1 or required > len(targets):
                    errors.append(f"{sid}: {fid} control_count required out of range")
                for target_value in targets:
                    target = coord_pair(target_value)
                    if not coord_in_bounds(target, w, h):
                        errors.append(f"{sid}: {fid} control target off-map {target_value}")
                    else:
                        terr = tile_at(rows, target)
                        if terr is None:
                            errors.append(f"{sid}: {fid} control target off-map {target_value}")
                        elif terr in impassable:
                            errors.append(f"{sid}: {fid} control target on impassable {terr}")

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
