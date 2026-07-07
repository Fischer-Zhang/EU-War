class_name Visibility
extends RefCounted

const HexCoord := preload("res://scripts/grid/hex_coord.gd")

# Hex line-of-sight + per-faction visibility (fog of war). Symmetric: every
# faction computes visibility for its own units. `hex_map` is duck-typed
# (needs terrain_at + blocks_los_at, optionally unit_at).

static func has_los(
	observer: Vector2i, target: Vector2i, hex_map,
	observer_faction: String = "", block_all_units: bool = false
) -> bool:
	# A non-endpoint hex whose terrain blocks LOS always interrupts. Units block:
	#   - block_all_units (direct fire): ANY unit on the line blocks.
	#   - observer_faction set (vision): only ENEMY units block.
	# Endpoints never block, so you can always see / fire INTO cover, not THROUGH.
	if observer == target:
		return true
	var check_units: bool = (block_all_units or observer_faction != "") and hex_map.has_method("unit_at")
	var path: Array = HexCoord.line(observer, target)
	for i in range(1, path.size() - 1):
		var hex: Vector2i = path[i]
		if hex_map.terrain_at(hex) == "":
			continue  # off-map
		if hex_map.blocks_los_at(hex):
			return false
		if check_units:
			var occupant = hex_map.unit_at(hex)
			if occupant != null and (block_all_units or occupant.faction_id != observer_faction):
				return false
	return true

static func compute_visible_hexes(
	units: Array, faction_id: String, hex_map, unit_defs: Dictionary = {}
) -> Dictionary:
	# Returns the set of hexes (Dictionary[Vector2i, true]) visible to any living
	# unit of `faction_id`.
	var visible: Dictionary = {}
	for u in units:
		var unit = u
		if not unit.is_alive() or unit.faction_id != faction_id:
			continue
		var unit_def: Dictionary = unit_defs.get(unit.type_id, {})
		var vision: int = int(unit_def.get("vision", 3))
		visible[unit.coord] = true
		for c in HexCoord.range_within(unit.coord, vision):
			var coord: Vector2i = c
			if hex_map.terrain_at(coord) == "":
				continue
			if has_los(unit.coord, coord, hex_map, faction_id):
				visible[coord] = true
	return visible
