extends SceneTree

# Verifies side selection: the player can control either faction. Covers the
# resolver (single-battle override + campaign side index), that a battle makes
# exactly the chosen faction human and the rest AI, that the roster carries the
# chosen side, and that taking a defensive side makes the AI press the attack.

var fails := 0

func ok(cond: bool, msg: String) -> void:
	if cond:
		print("  PASS: ", msg)
	else:
		fails += 1
		printerr("  FAIL: ", msg)

func _init() -> void:
	_run.call_deferred()

func _run() -> void:
	var gs = root.get_node("GameState")
	var dl = root.get_node("DataLoader")
	await process_frame

	var scen: Dictionary = dl.get_scenario("02_crecy_1346")
	var facs: Array = scen.get("factions", [])
	var f0 := String(facs[0].get("id", ""))   # england (default player, defensive)
	var f1 := String(facs[1].get("id", ""))   # france (default AI)

	# Resolver: default single-battle = the declared player faction.
	gs.clear_campaign()
	gs.clear_conquest()
	gs.player_faction_override = ""
	ok(gs.resolve_player_faction(scen) == f0, "default single-battle player = declared side (%s)" % f0)

	# Resolver: a single-battle override flips the human to the other faction.
	gs.player_faction_override = f1
	ok(gs.resolve_player_faction(scen) == f1, "override flips single-battle player to %s" % f1)
	gs.player_faction_override = "bogus"
	ok(gs.resolve_player_faction(scen) == f0, "invalid override falls back to default side")
	gs.player_faction_override = ""

	# Resolver: campaign side picks the faction INDEX across scenarios.
	var cid := "hundred_years_war"
	gs.start_campaign(cid, 0)
	var s0: Dictionary = dl.get_scenario(gs.current_campaign_scenario())
	ok(gs.resolve_player_faction(s0) == String(s0.factions[0].get("id", "")), "campaign side 0 = faction index 0")
	gs.start_campaign(cid, 1)
	var s1: Dictionary = dl.get_scenario(gs.current_campaign_scenario())
	ok(gs.resolve_player_faction(s1) == String(s1.factions[1].get("id", "")), "campaign side 1 = faction index 1")

	# Roster carries the chosen side: with side 1, apply_roster fills faction 1.
	gs.campaign_roster = [{"type": "longbowmen", "name": "老兵", "xp": 5, "rank": 2, "general": ""}]
	var applied: Dictionary = gs.apply_roster(s1)
	var target_fid := String(s1.factions[1].get("id", ""))
	var carried := false
	for u in applied.get("units", []):
		if String(u.get("faction", "")) == target_fid and int(u.get("xp", 0)) == 5:
			carried = true
	ok(carried, "roster veteran carried into the chosen side (%s)" % target_fid)
	gs.clear_campaign()

	# In a real battle, exactly the chosen faction is human; the rest are AI.
	gs.player_faction_override = f1
	gs.current_scenario_id = "02_crecy_1346"
	var b = load("res://scenes/battle.tscn").instantiate()
	root.add_child(b)
	for _i in range(10):
		await process_frame
	ok(b.player_faction == f1, "battle player_faction honours the override (%s)" % b.player_faction)
	ok(not b._is_ai(f1), "chosen faction is human-controlled")
	ok(b._is_ai(f0), "the other faction is AI-controlled")
	b.queue_free()
	await process_frame

	# Taking the defensive side makes the AI opponent press the attack.
	gs.player_faction_override = f0   # england is defensive at Crecy
	var b2 = load("res://scenes/battle.tscn").instantiate()
	root.add_child(b2)
	for _i in range(10):
		await process_frame
	ok(String(b2.factions[f1].get("posture", "")) == "aggressive",
		"AI opponent turns aggressive when the human defends")
	b2.queue_free()
	await process_frame
	gs.player_faction_override = ""

	if fails == 0:
		print("test_side_select: ok")
		quit(0)
	else:
		printerr("test_side_select: %d failures" % fails)
		quit(1)
