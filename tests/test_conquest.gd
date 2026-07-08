extends SceneTree

# Verifies the conquest strategic layer incl. the enemy counter-attack loop:
# starting ownership, the frontline attack rule, capture-on-win, the enemy
# queueing a counter after the player's attack, defending (win secures, loss
# loses the territory), the "secured" rule preventing repeat counters, the win
# condition, and the map screen build.

var fails := 0

func ok(cond: bool, msg: String) -> void:
	if cond:
		print("  PASS: ", msg)
	else:
		fails += 1
		printerr("  FAIL: ", msg)

func _init() -> void:
	_run.call_deferred()

func _first_attackable(gs) -> String:
	for t in gs.conquest_territories():
		var tid = String(t.get("id", ""))
		if gs.territory_attackable(tid):
			return tid
	return ""

func _run() -> void:
	var gs = root.get_node("GameState")
	var dl = root.get_node("DataLoader")
	await process_frame

	var qid = String(dl.conquests.keys()[0])
	gs.start_conquest(qid)
	ok(gs.in_conquest(), "in_conquest() after start")
	ok(gs.conquest_owner.get("home", "") == "player", "home starts player-owned")
	ok(not gs.conquest_won(), "not won at start")
	ok(not gs.has_enemy_counter(), "no enemy counter at start")

	# Frontline + refusing a deep target.
	ok(gs.territory_attackable("normandy") and gs.territory_attackable("lombardy"), "initial frontline = normandy + lombardy")
	ok(not gs.territory_attackable("lowlands"), "deep enemy territory not attackable")
	ok(not gs.begin_conquest_attack("lowlands"), "attacking a non-frontline territory refused")

	# Attack normandy and win -> captured, and the enemy queues a counter.
	ok(gs.begin_conquest_attack("normandy"), "begin attack on normandy")
	ok(gs.current_scenario_id == "02_crecy_1346", "battle scenario = territory's scenario")
	gs.resolve_conquest_battle(true)
	ok(gs.conquest_owner.get("normandy", "") == "player", "normandy captured on win")
	ok(gs.has_enemy_counter(), "enemy queues a counter-attack after the player's attack")

	# While a counter is pending, the player can't launch a new attack.
	ok(not gs.begin_conquest_attack("lombardy"), "can't attack while defending a counter")

	# Defend and win -> the territory is secured; enemy turn is spent.
	ok(gs.begin_conquest_defense(), "begin defense of the counter-attacked territory")
	var defended = String(gs.conquest_battle.get("territory", ""))
	gs.resolve_conquest_battle(true)
	ok(gs.conquest_secured.has(defended), "winning the defense secures the territory")
	ok(not gs.has_enemy_counter(), "enemy counter consumed after defense")
	ok(gs.conquest_owner.get(defended, "") == "player", "defended territory stays player-owned")

	# A secured territory is not counter-attacked again.
	# Capture the next frontier, then check the enemy doesn't re-target the secured one.
	var nxt = _first_attackable(gs)
	ok(nxt != "", "a new frontier opened after securing")
	gs.begin_conquest_attack(nxt)
	gs.resolve_conquest_battle(true)
	ok(gs.conquest_enemy_target != defended, "enemy does not re-attack a secured territory")

	# Losing a defense loses the territory.
	if gs.has_enemy_counter():
		var t2 = gs.conquest_enemy_target
		gs.begin_conquest_defense()
		gs.resolve_conquest_battle(false)
		ok(gs.conquest_owner.get(t2, "") == "enemy", "losing the defense hands the territory back")

	# Perfect-player playthrough terminates in a win (securing prevents loops).
	gs.start_conquest(qid)
	var steps = 0
	while not gs.conquest_won() and steps < 60:
		steps += 1
		if gs.has_enemy_counter():
			gs.begin_conquest_defense()
			gs.resolve_conquest_battle(true)
		else:
			var tid = _first_attackable(gs)
			if tid == "":
				break
			gs.begin_conquest_attack(tid)
			gs.resolve_conquest_battle(true)
	ok(gs.conquest_won(), "a perfect player conquers everything (in %d steps)" % steps)

	# Map builds.
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
