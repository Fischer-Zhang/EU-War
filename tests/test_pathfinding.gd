extends SceneTree

const Pathfinding := preload("res://scripts/grid/pathfinding.gd")
const HexCoord := preload("res://scripts/grid/hex_coord.gd")

# Minimal duck-typed hex map: a rectangular block of plain with a couple of
# impassable "river" hexes.
class StubMap:
	extends RefCounted
	var w: int
	var h: int
	var impass: Dictionary = {}
	func _init(_w: int, _h: int) -> void:
		w = _w
		h = _h
	func _in_bounds(c: Vector2i) -> bool:
		var col := c.x + (c.y >> 1)  # axial -> offset col
		return c.y >= 0 and c.y < h and col >= 0 and col < w
	func terrain_at(c: Vector2i) -> String:
		if not _in_bounds(c):
			return ""
		return "river" if impass.has(c) else "plain"
	func move_cost_at(_c: Vector2i) -> int:
		return 1
	func terrain_impassable(t: String) -> bool:
		return t == "river"
	func is_bridged(_c: Vector2i) -> bool:
		return false

func _init() -> void:
	var pass_count := 0
	var fail_count := 0

	var m := StubMap.new(9, 9)
	var start := Vector2i(4, 4)

	# Move 1 on open ground reaches exactly the 6 neighbors.
	var reach1 := Pathfinding.movement_range(start, 1, m, {}, "", "")
	if reach1.size() == 6:
		pass_count += 1
	else:
		fail_count += 1; printerr("FAIL: reach move=1 size=%d" % reach1.size())

	# A reconstructed path to an adjacent hex is start + goal.
	var goal := start + Vector2i(1, 0)
	var reach2 := Pathfinding.movement_range(start, 3, m, {}, "", "")
	var path := Pathfinding.reconstruct_path(start, goal, reach2, m, {}, "", "")
	if path.size() == 2 and path[0] == start and path[-1] == goal:
		pass_count += 1
	else:
		fail_count += 1; printerr("FAIL: path %s" % str(path))

	# An occupied hex blocks entry.
	var occ := {goal: RefCounted.new()}
	var reach3 := Pathfinding.movement_range(start, 1, m, occ, "", "")
	if not reach3.has(goal):
		pass_count += 1
	else:
		fail_count += 1; printerr("FAIL: occupied not blocked")

	# Impassable river is never entered.
	var river := start + Vector2i(0, 1)
	m.impass[river] = true
	var reach4 := Pathfinding.movement_range(start, 2, m, {}, "", "")
	if not reach4.has(river):
		pass_count += 1
	else:
		fail_count += 1; printerr("FAIL: river entered")

	print("test_pathfinding: %d passed, %d failed" % [pass_count, fail_count])
	quit(1 if fail_count > 0 else 0)
