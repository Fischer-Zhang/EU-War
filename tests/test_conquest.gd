extends SceneTree

# Verifies the conquest strategic layer: starting ownership, the frontline
# attack rule (only enemy territories adjacent to an owned one), capturing on a
# win, the frontline advancing as territories fall, and the win condition. Also
# exercises the conquest map screen build.

var fails := 0

func ok(cond: bool, msg: String) -> void:
	if cond:
		print("  PASS: ", msg)
	else:
		fails += 1
		printerr("  FAIL: ", msg)

func _init() -> void:
	_run.call_deferred()

func _attackable_set(gs) -> Dictionary:
	var out := {}
	for t in gs.conquest_territories():
		var tid = String(t.get("id", ""))
		if gs.territory_attackable(tid):
			out[tid] = true
	return out

func _run() -> void:
	var gs = root.get_node("GameState")
	var dl = root.get_node("DataLoader")
	await process_frame

	var qid = String(dl.conquests.keys()[0])
	gs.start_conquest(qid)
	ok(gs.in_conquest(), "in_conquest() after start")
	ok(gs.conquest_owner.get("home", "") == "player", "home starts player-owned")
	ok(gs.conquest_owner.get("lowlands", "") == "enemy", "lowlands starts enemy-owned")
	ok(not gs.conquest_won(), "not won at start")

	# Frontline: only enemy territories adjacent to home are attackable.
	var front = _attackable_set(gs)
	ok(front.has("normandy") and front.has("lombardy"), "initial frontline = normandy + lombardy")
	ok(not front.has("lowlands"), "deep enemy territory not attackable yet")
	ok(not front.has("home"), "own territory not attackable")

	# Can't attack a non-frontline territory.
	ok(not gs.begin_conquest_attack("lowlands"), "attacking a non-frontline territory refused")

	# Attack + capture normandy: sets the scenario, then a win flips ownership.
	ok(gs.begin_conquest_attack("normandy"), "begin attack on frontline normandy")
	ok(gs.conquest_target == "normandy", "conquest_target set")
	ok(gs.current_scenario_id == "02_crecy_1346", "battle scenario = territory's scenario")
	gs.capture_conquest_target()  # simulate a battle win
	ok(gs.conquest_owner.get("normandy", "") == "player", "normandy captured on win")
	ok(gs.conquest_target == "", "target cleared after capture")

	# Frontline advanced: picardy (behind normandy) is now attackable.
	ok(gs.territory_attackable("picardy"), "frontline advances to picardy after normandy falls")

	# Capture everything → win.
	for tid in ["picardy", "lombardy", "rhineland", "lowlands"]:
		# each must be on the frontline when we reach it
		gs.begin_conquest_attack(tid)
		gs.capture_conquest_target()
	ok(gs.conquest_won(), "conquest won after capturing all enemy territories")
	var counts = gs.conquest_counts()
	ok(counts.player == counts.total, "all territories player-owned")

	# Conquest map screen builds without error (reset to a fresh conquest first).
	gs.start_conquest(qid)
	var map = load("res://scenes/conquest_map.tscn").instantiate()
	root.add_child(map)
	await process_frame
	await process_frame
	ok(map.get_child_count() > 0, "conquest map builds nodes")
	map.queue_free()
	await process_frame

	gs.clear_conquest()
	ok(not gs.in_conquest(), "clear_conquest resets state")

	if fails == 0:
		print("test_conquest: ok")
		quit(0)
	else:
		printerr("test_conquest: %d failures" % fails)
		quit(1)
