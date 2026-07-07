extends SceneTree

# Verifies campaign chaining: starting a campaign points at its first scenario,
# apply_roster is a no-op on battle 1, capturing survivors banks their XP/rank,
# advancing moves to the next scenario, and apply_roster then replaces the
# player force with the carried roster on the scenario's own player slots.

var fails := 0

func ok(cond: bool, msg: String) -> void:
	if cond:
		print("  PASS: ", msg)
	else:
		fails += 1
		printerr("  FAIL: ", msg)

# Minimal stand-in for a Unit — capture_roster only reads these fields.
class FakeUnit:
	var type_id: String
	var display_name: String
	var xp: int
	var rank: int
	var general_id: String
	func _init(t, n, x, r, g = ""):
		type_id = t; display_name = n; xp = x; rank = r; general_id = g

func _init() -> void:
	_run.call_deferred()

func _run() -> void:
	var gs = root.get_node("GameState")
	var dl = root.get_node("DataLoader")
	await process_frame

	var cid = String(dl.campaigns.keys()[0])
	var scens: Array = dl.get_campaign(cid).get("scenarios", [])
	ok(scens.size() >= 2, "campaign has at least two scenarios")

	gs.start_campaign(cid)
	ok(gs.in_campaign(), "in_campaign() true after start")
	ok(gs.campaign_index == 0, "starts at index 0")
	ok(gs.current_scenario_id == String(scens[0]), "current scenario is battle 1")

	# Battle 1: roster empty -> apply_roster leaves the scenario untouched.
	var s0 = dl.get_scenario(String(scens[0]))
	var pf := ""
	for f in s0.get("factions", []):
		if f.get("controller") == "player":
			pf = f.get("id")
	var s0_applied = gs.apply_roster(s0)
	var s0_players := _count_faction(s0_applied, pf)
	ok(s0_players == _count_faction(s0, pf), "battle 1 player force unchanged (empty roster)")

	# Capture two survivors with veteran progress.
	gs.capture_roster([
		FakeUnit.new("longbowmen", "老練長弓", 7, 2),
		FakeUnit.new("men_at_arms", "百戰騎士", 4, 1),
	])
	ok(gs.campaign_roster.size() == 2, "roster captured 2 survivors")
	ok(int(gs.campaign_roster[0].xp) == 7 and int(gs.campaign_roster[0].rank) == 2, "veteran XP/rank preserved")

	gs.advance_campaign()
	ok(gs.campaign_index == 1, "advanced to index 1")
	ok(not gs.campaign_complete(), "campaign not yet complete")
	ok(gs.current_scenario_id == String(scens[1]), "current scenario is battle 2")

	# Battle 2: roster replaces the player force onto the scenario's slots.
	var s1 = dl.get_scenario(String(scens[1]))
	var s1_applied = gs.apply_roster(s1)
	var players := _players_of(s1_applied, pf)
	ok(players.size() == 2, "battle 2 player force = roster size (2)")
	var types := []
	for u in players:
		types.append(u.get("type"))
	ok("longbowmen" in types and "men_at_arms" in types, "roster unit types placed")
	var carried_xp := false
	for u in players:
		if int(u.get("xp", 0)) == 7:
			carried_xp = true
	ok(carried_xp, "carried unit keeps its XP into battle 2")
	# Placed on the scenario's own player slot positions.
	var slot_positions := []
	for u in _players_of(s1, pf):
		slot_positions.append(u.get("at"))
	var on_slots := true
	for u in players:
		if not (u.get("at") in slot_positions):
			on_slots = false
	ok(on_slots, "roster placed on scenario's player slots")

	# Enemy force untouched.
	ok(_count_faction(s1_applied, pf) + _enemy_count(s1_applied, pf) == players.size() + _enemy_count(s1, pf),
		"enemy force preserved")

	# Completing the last battle.
	gs.advance_campaign()
	ok(gs.campaign_complete(), "campaign complete after last battle")
	gs.clear_campaign()
	ok(not gs.in_campaign(), "clear_campaign resets state")

	# The shared select screen lists every campaign in campaign-browse mode.
	gs.browsing_campaigns = true
	var sel = load("res://scenes/scenario_select.tscn").instantiate()
	root.add_child(sel)
	await process_frame
	await process_frame
	var list_node = sel.get_node("Margin/VBox/ListScroll/List")
	ok(list_node.get_child_count() == dl.campaigns.size(),
		"campaign select lists all %d campaigns" % dl.campaigns.size())
	sel.queue_free()
	await process_frame
	gs.browsing_campaigns = false

	if fails == 0:
		print("test_campaign: ok")
		quit(0)
	else:
		printerr("test_campaign: %d failures" % fails)
		quit(1)

func _players_of(scenario: Dictionary, pf: String) -> Array:
	var out := []
	for u in scenario.get("units", []):
		if u.get("faction") == pf:
			out.append(u)
	return out

func _count_faction(scenario: Dictionary, pf: String) -> int:
	return _players_of(scenario, pf).size()

func _enemy_count(scenario: Dictionary, pf: String) -> int:
	var n := 0
	for u in scenario.get("units", []):
		if u.get("faction") != pf:
			n += 1
	return n
