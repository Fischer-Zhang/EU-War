class_name AIController
extends RefCounted

# Deterministic tactical AI. The battle scene asks the controller for one order
# per living, ready unit; the controller scores movement destinations and picks
# the best attack (or an approach toward the nearest enemy).
#
# Difficulty is a weight ladder over aggression, counter-risk aversion and unit
# preservation. Hard presses attacks and shields veterans; Easy is timid, keeps
# its distance and occasionally misplaces a unit. All axes run at every level —
# only the weights change — so the ladder is a smooth ramp, not a feature toggle.

const HexCoord := preload("res://scripts/grid/hex_coord.gd")
const Pathfinding := preload("res://scripts/grid/pathfinding.gd")
const Visibility := preload("res://scripts/grid/visibility.gd")
const CombatRules := preload("res://scripts/combat/combat_rules.gd")
const CombatResolver := preload("res://scripts/combat/combat_resolver.gd")
const CombatModifiers := preload("res://scripts/combat/combat_modifiers.gd")
const CombatEffects := preload("res://scripts/combat/combat_effects.gd")

var difficulty: String = "normal"
var weights: Dictionary = {}

# An order the battle executes: move along `path` (start..dest), then act.
class Order:
	var unit                      # Unit to act
	var path: Array = []          # movement path incl. start; empty = stay
	var dest: Vector2i            # final hex
	var target = null             # Unit to attack, or null
	var action: String = "wait"   # "attack" | "entrench" | "rally" | "wait"

func _init(_difficulty: String = "normal") -> void:
	difficulty = _difficulty
	weights = _weights_for(difficulty)

static func _weights_for(d: String) -> Dictionary:
	match d:
		"easy":
			return {"aggression": 0.6, "counter_risk": 1.4, "preservation": 0.4,
				"kill_bonus": 8.0, "advance": 0.6, "misplay": true, "retreat": false}
		"hard":
			return {"aggression": 1.4, "counter_risk": 0.7, "preservation": 1.3,
				"kill_bonus": 16.0, "advance": 1.2, "misplay": false, "retreat": true}
		_:
			return {"aggression": 1.0, "counter_risk": 1.0, "preservation": 1.0,
				"kill_bonus": 12.0, "advance": 1.0, "misplay": false, "retreat": true}

func plan_unit(unit, units: Array, hex_map, factions: Dictionary) -> Order:
	var order := Order.new()
	order.unit = unit
	order.dest = unit.coord
	if unit.routed:
		return order  # broken formations withdraw on their own; skip

	var faction: String = unit.faction_id
	var unit_def: Dictionary = DataLoader.get_unit_def(unit.type_id)
	var general_def: Dictionary = DataLoader.get_general_def(unit.general_id)
	var visible: Dictionary = Visibility.compute_visible_hexes(units, faction, hex_map, DataLoader.units)

	var occupied := _occupancy(units)
	var mp: int = unit.effective_move(unit_def, general_def)
	var reach: Dictionary = Pathfinding.movement_range(
		unit.coord, mp, hex_map, occupied, faction, unit.type_id)
	# Candidate destinations: staying put plus every reachable hex, in a stable order.
	var candidates: Array = [unit.coord]
	var reach_keys := reach.keys()
	reach_keys.sort_custom(func(a, b): return a.y * 10000 + a.x < b.y * 10000 + b.x)
	for c in reach_keys:
		candidates.append(c)

	var best_score := -INF
	var best: Order = order
	for cand in candidates:
		var eval := _score_destination(unit, cand, unit_def, general_def, units, hex_map, visible, faction)
		var score: float = eval["score"]
		if score > best_score:
			best_score = score
			best = Order.new()
			best.unit = unit
			best.dest = cand
			best.path = Pathfinding.reconstruct_path(
				unit.coord, cand, reach, hex_map, occupied, faction, unit.type_id) if cand != unit.coord else []
			best.target = eval["target"]
			best.action = eval["action"]

	# Easy occasionally fumbles the destination (deterministic: keyed off unit coord).
	if weights.get("misplay", false) and best.target == null and not best.path.is_empty():
		if (absi(unit.coord.x * 7 + unit.coord.y * 13)) % 5 == 0:
			best.path = []
			best.dest = unit.coord
			best.action = "wait"
	return best

func _score_destination(unit, cand: Vector2i, unit_def: Dictionary, general_def: Dictionary,
		units: Array, hex_map, visible: Dictionary, faction: String) -> Dictionary:
	var atk_mods: Dictionary = CombatModifiers.for_unit(unit, general_def)
	var terrain_def: Dictionary = _terrain_def(hex_map, cand)
	var score := 0.0
	# Cover value at the destination.
	score += float(int(terrain_def.get("defense", 0)))

	# Best attack available from this hex. Landing a hit is the PRIMARY driver:
	# it must outweigh the incidental exposure of stepping into reach, or the AI
	# would perpetually hover just outside contact and never fight.
	var best_target = null
	var best_attack_score := 0.0
	for u in units:
		if u.faction_id == faction or not u.is_alive():
			continue
		if not CombatRules.can_attack_from_coord(cand, faction, u, unit_def, hex_map, visible):
			continue
		var dist := HexCoord.distance(cand, u.coord)
		var eval := _attack_value(unit, unit_def, atk_mods, u, hex_map, dist, terrain_def)
		if eval > best_attack_score:
			best_attack_score = eval
			best_target = u
	score += best_attack_score * 2.0 * float(weights["aggression"])

	# Exposure only NUDGES positioning (prefer the safer of two attacking hexes,
	# or hang back a little when wounded/veteran) — it can't veto a good attack.
	var exposure: float = min(_exposure_at(cand, unit, unit_def, atk_mods, units, hex_map, visible, faction),
		float(unit.hp) * 1.5)
	var preserve: float = float(weights["preservation"]) * _preservation_scale(unit)
	score -= exposure * 0.25 * float(weights["counter_risk"]) * preserve

	# Advance toward the nearest enemy — strong enough to force contact when no
	# attack is yet in reach.
	var nearest := _nearest_enemy_distance(cand, units, faction)
	if nearest >= 0:
		score -= float(nearest) * float(weights["advance"])

	var action := "attack" if best_target != null else "wait"
	# No target, sitting in cover under threat → dig in rather than idle.
	if best_target == null and exposure > 3.0 and int(terrain_def.get("defense", 0)) > 0:
		action = "entrench"
	return {"score": score, "target": best_target, "action": action}

func _attack_value(unit, unit_def: Dictionary, atk_mods: Dictionary,
		target, hex_map, dist: int, atk_terrain_def: Dictionary) -> float:
	var def_def: Dictionary = DataLoader.get_unit_def(target.type_id)
	var def_general: Dictionary = DataLoader.get_general_def(target.general_id)
	var def_mods: Dictionary = CombatModifiers.for_unit(target, def_general)
	var def_terrain: Dictionary = _terrain_def(hex_map, target.coord)
	var result := CombatResolver.resolve(
		unit_def, def_def, unit.hp, target.hp, atk_terrain_def, def_terrain,
		dist, target.dig_in_level, atk_mods, def_mods, false)
	var value := float(result.damage_to_defender)
	if result.defender_dies:
		value += weights["kill_bonus"]
	value += float(result.suppression_to_defender) * 0.5
	value -= float(result.counter_damage) * weights["counter_risk"] * 0.6
	return value

func _exposure_at(cand: Vector2i, unit, unit_def: Dictionary, _atk_mods: Dictionary,
		units: Array, hex_map, _visible: Dictionary, faction: String) -> float:
	var terrain_def: Dictionary = _terrain_def(hex_map, cand)
	var total := 0.0
	for u in units:
		if u.faction_id == faction or not u.is_alive():
			continue
		var edef: Dictionary = DataLoader.get_unit_def(u.type_id)
		var emp: int = int(edef.get("move", 0))
		var rng: int = int(edef.get("range", 1))
		# Can this enemy plausibly reach striking distance of `cand` next turn?
		if HexCoord.distance(u.coord, cand) > emp + rng:
			continue
		var egen: Dictionary = DataLoader.get_general_def(u.general_id)
		var emods: Dictionary = CombatModifiers.for_unit(u, egen)
		var result := CombatResolver.resolve(
			edef, unit_def, u.hp, unit.hp, _terrain_def(hex_map, u.coord), terrain_def,
			1, unit.dig_in_level, emods, {}, false)
		total += float(result.damage_to_defender)
	return total

func _preservation_scale(unit) -> float:
	# Wounded and veteran units are worth protecting more.
	var scale := 1.0
	scale += float(unit.rank) * 0.4
	var hp_ratio := float(unit.hp) / float(max(1, unit.max_hp))
	if hp_ratio < 0.5:
		scale += 0.6
	return scale

func _nearest_enemy_distance(from: Vector2i, units: Array, faction: String) -> int:
	var best := -1
	for u in units:
		if u.faction_id == faction or not u.is_alive():
			continue
		var d := HexCoord.distance(from, u.coord)
		if best < 0 or d < best:
			best = d
	return best

func _terrain_def(hex_map, coord: Vector2i) -> Dictionary:
	var tid: String = hex_map.terrain_at(coord)
	if tid == "":
		return {}
	return DataLoader.get_terrain_def(tid)

func _occupancy(units: Array) -> Dictionary:
	var occ := {}
	for u in units:
		if u.is_alive():
			occ[u.coord] = u
	return occ

static func _coord_key(c: Vector2i) -> int:
	return c.y * 10000 + c.x
