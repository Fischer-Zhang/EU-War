extends SceneTree

# Verifies the MULTI-FACTION conquest strategic layer with the BATTLEFIELD-ARMY
# system: positioned armies that move/attack, army-vs-army + garrison resolution,
# per-army rosters, the AI army turn, capture+advance, elimination, victory/defeat,
# diplomacy truces, deterministic events, economy (muster/recruit/heal on the
# player's army), save/load of armies, and the map build. Driven by "test_arena".

var fails := 0

class FakeUnit:
	extends RefCounted
	var type_id: String
	var display_name: String
	var xp: int
	var rank: int
	var general_id: String
	func _init(t, x, r):
		type_id = t; display_name = t; xp = x; rank = r; general_id = ""

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

func _armies_snapshot(gs) -> String:
	var parts := []
	for a in gs.conquest_armies:
		parts.append("%s@%s:%d" % [String(a.get("id", "")), String(a.get("location", "")), int(a.get("strength", 0))])
	parts.sort()
	return ", ".join(parts)

func _run() -> void:
	var gs = root.get_node("GameState")
	var dl = root.get_node("DataLoader")
	await process_frame
	var qid = "test_arena"

	# --- Setup: powers, owners, synthesized armies ---
	gs.start_conquest(qid)
	ok(gs.in_conquest() and gs.player_power_id == "blue", "started; player = blue")
	ok(gs.conquest_powers.size() == 3, "three powers loaded")
	ok(gs.conquest_armies.size() == 3, "one army synthesized per power")
	ok(gs.armies_at("b_cap").size() == 1 and String(gs.armies_at("b_cap")[0].get("owner", "")) == "blue", "blue army at its capital")
	ok(not gs.conquest_over(), "no result at start")

	# --- Per-power supply + income (unchanged) ---
	ok(gs.conquest_supplied_for("blue").has("b_mine"), "blue city supplies its resource")
	ok(gs.conquest_income_for("blue") == 3, "blue income = city base(1) + mine yield(2)")

	# --- Army combat + movement primitives ---
	var ba: Dictionary = gs.army_by_id("blue#0")
	ok(gs._army_attack_value(ba, "r_cap") <= gs._defense_value("r_cap"), "even armies: attacker repulsed (ties favour defender)")
	ba["strength"] = 4
	ok(gs._resolve_army_attack(ba, "r_cap"), "a strong army takes the city")
	ok(String(gs.conquest_owner.get("r_cap", "")) == "blue" and String(ba.get("location", "")) == "r_cap", "winner captures and advances")
	ok(gs.army_by_id("red#0").is_empty(), "the defending army is destroyed")
	gs.start_conquest(qid)
	gs._destroy_army("red#0")
	var ba2: Dictionary = gs.army_by_id("blue#0"); ba2["strength"] = 4
	ok(gs._resolve_army_attack(ba2, "r_cap"), "an army-less city (garrison only) falls to a strong army")
	gs.start_conquest(qid)
	ok(gs.can_move_army("blue#0", "b_mine"), "can move to adjacent own empty tile")
	ok(not gs.can_move_army("blue#0", "r_cap"), "cannot move into enemy territory")
	ok(gs.move_army("blue#0", "b_mine") and String(gs.army_by_id("blue#0").get("location", "")) == "b_mine", "move relocates the army")
	ok(not gs.can_move_army("blue#0", "b_cap"), "an army that acted cannot move again")

	# --- Player attack via begin_conquest_attack (auto-selects the adjacent army) ---
	gs.start_conquest(qid)
	ok(gs.territory_attackable("r_cap"), "adjacent enemy city is attackable")
	ok(not gs.territory_attackable("g_cap"), "no player army adjacent to green")
	ok(gs.begin_conquest_attack("r_cap"), "begin attack auto-selects the fielding army")
	ok(String(gs.conquest_battle.get("army", "")) == "blue#0" and String(gs.conquest_battle.get("defender", "")) == "red", "battle records fielding army + defender")
	gs.resolve_conquest_battle(true)
	ok(String(gs.conquest_owner.get("r_cap", "")) == "blue", "win captures the city")
	ok(String(gs.army_by_id("blue#0").get("location", "")) == "r_cap", "army advances into the captured tile")
	ok(gs.army_by_id("red#0").is_empty() and gs._is_eliminated("red"), "defender army destroyed; red eliminated")

	# --- AI army turn: determinism ---
	gs.start_conquest(qid)
	gs.advance_conquest_round()
	var snap1 := _armies_snapshot(gs)
	gs.start_conquest(qid)
	gs.advance_conquest_round()
	ok(_armies_snapshot(gs) == snap1, "AI army turn is deterministic across runs")

	# --- AI army attacks the player's army -> defence; losing the last city = defeat ---
	gs.start_conquest(qid)
	gs.army_by_id("red#0")["strength"] = 4
	gs.advance_conquest_round()
	var pend: Array = gs.conquest_pending_defenses()
	ok(pend.size() >= 1 and String(pend[0].get("territory", "")) == "b_cap", "a strong AI army queues an attack on the player's city")
	ok(gs.begin_conquest_defense(), "player begins the defence")
	ok(String(gs.conquest_battle.get("army", "")) == "blue#0" and String(gs.conquest_battle.get("enemy_army", "")) == "red#0", "defence records both armies")
	gs.resolve_conquest_battle(false)
	ok(String(gs.conquest_owner.get("b_cap", "")) == "red", "losing the defence hands the tile to the attacker")
	ok(gs.army_by_id("blue#0").is_empty(), "defending army destroyed on loss")
	ok(gs.conquest_lost(), "losing the last city is defeat")

	# --- Undefended city falls to an AI army with no player battle ---
	gs.start_conquest(qid)
	gs._destroy_army("blue#0")
	gs.army_by_id("red#0")["strength"] = 4
	gs.advance_conquest_round()
	ok(String(gs.conquest_owner.get("b_cap", "")) == "red" and gs.conquest_lost(), "an undefended player city is taken by an AI army (garrison auto-resolve)")

	# --- Sole-survivor victory (perfect player) ---
	gs.start_conquest(qid)
	var steps = 0
	while not gs.conquest_over() and steps < 40:
		steps += 1
		if gs.has_enemy_counter():
			gs.begin_conquest_defense(); gs.resolve_conquest_battle(true); continue
		var tgt = _first_attackable(gs)
		if tgt != "":
			gs.begin_conquest_attack(tgt); gs.resolve_conquest_battle(true)
		else:
			gs.advance_conquest_round()
	ok(gs.conquest_won(), "a perfect player becomes the sole surviving power (in %d steps)" % steps)

	# --- Economy: muster/recruit/heal act on the player's primary army ---
	gs.start_conquest(qid)
	gs.conquest_strength = 30
	var pa: Dictionary = gs._player_primary_army()
	ok(not pa.is_empty(), "player has a primary army on a supplied city")
	var s0: int = int(pa.get("strength", 1))
	ok(gs.muster() and int(gs._player_primary_army().get("strength", 1)) == s0 + 1, "muster reinforces the army's strength")
	var r0: int = gs._player_primary_army().get("roster", []).size()
	ok(gs.recruit() and gs._player_primary_army().get("roster", []).size() == r0 + 1, "recruit adds a unit to the army roster")
	gs._player_primary_army()["roster"] = [{"type": "musketeers", "name": "x", "xp": 0, "rank": 0, "general": ""}]
	ok(gs.heal() and int(gs._player_primary_army().get("roster", [])[0].get("rank", 0)) == 1, "heal ranks up the army's weakest unit")

	# --- Diplomacy: truce blocks attacks both ways ---
	gs.start_conquest(qid)
	gs.conquest_strength = 20
	ok(gs.offer_truce("red") and gs.at_truce("red"), "offer a truce to red")
	ok(not gs.territory_attackable("r_cap"), "cannot attack a power you're at truce with")
	gs.army_by_id("red#0")["strength"] = 4
	gs.advance_conquest_round()
	var red_hits := false
	for e in gs.conquest_pending_defenses():
		if String(e.get("attacker", "")) == "red": red_hits = true
	ok(not red_hits, "a truced AI does not attack the player")

	# --- Events act on the player's primary army roster ---
	gs.start_conquest(qid)
	var pr0: int = gs._player_primary_army().get("roster", []).size()
	gs._apply_event({"kind": "recruit"})
	ok(gs._player_primary_army().get("roster", []).size() == pr0 + 1, "recruit event adds to the army roster")
	gs._apply_event({"kind": "resource", "amount": -100})
	ok(gs.conquest_strength == 0, "resource loss floors at zero")
	gs.start_conquest(qid); gs.advance_conquest_round()
	var ev1 = String(gs.conquest_last_event.get("id", ""))
	gs.start_conquest(qid); gs.advance_conquest_round()
	ok(ev1 == String(gs.conquest_last_event.get("id", "")), "events are deterministic across runs")

	# --- Real battle: fielding + enemy army strength, training, barrage ---
	gs.start_conquest(qid)
	gs.army_by_id("blue#0")["strength"] = 3
	gs.army_by_id("red#0")["strength"] = 3
	gs.conquest_training = 1
	gs.conquest_prep = {"barrage": true}
	gs.begin_conquest_attack("r_cap")
	var b = load("res://scenes/battle.tscn").instantiate()
	root.add_child(b)
	for _i in range(10):
		await process_frame
	var sample = null
	var enemy_sample = null
	for u in b.units:
		if u.faction_id == b.player_faction:
			if sample == null: sample = u
		elif enemy_sample == null:
			enemy_sample = u
	var army_buff := false
	if sample != null:
		for e in sample.active_effects:
			if int(e.get("self_mods", {}).get("attack", 0)) >= 3: army_buff = true
	ok(army_buff, "the fielding army's strength buffs the player's units")
	ok(sample != null and sample.xp >= gs.CONQ_TRAIN_XP, "training grants start XP")
	var enemy_buff := false
	if enemy_sample != null:
		for e in enemy_sample.active_effects:
			if int(e.get("self_mods", {}).get("attack", 0)) >= 3: enemy_buff = true
	ok(enemy_buff, "the enemy army's strength buffs its units")
	ok(enemy_sample != null and (enemy_sample.suppression > 0 or enemy_sample.hp < enemy_sample.max_hp), "barrage prep softens the enemy")
	b.queue_free()
	await process_frame
	# The battle relabels factions to the real powers.
	gs.start_conquest(qid)
	gs.begin_conquest_attack("r_cap")
	var cs2: Dictionary = gs.apply_conquest_faction_labels(dl.get_scenario(gs.current_scenario_id))
	var pf: String = gs.resolve_player_faction(cs2)
	for f in cs2.get("factions", []):
		if String(f.get("id", "")) == pf:
			ok(String(f.get("name", "")) == String(gs.conquest_power("blue").get("name", "")), "battle shows the player's real power name")

	# --- Save / load round-trip (armies + economy + result) ---
	gs.start_conquest(qid)
	gs.begin_conquest_attack("r_cap"); gs.resolve_conquest_battle(true)
	gs.conquest_strength = 17
	gs.save_conquest()
	ok(gs.has_conquest_save(), "conquest autosaves")
	var owners := {}
	for t in gs.conquest_territories(): owners[t.id] = String(gs.conquest_owner.get(t.id, ""))
	var asnap := _armies_snapshot(gs)
	gs.clear_conquest()
	ok(gs.load_conquest() and gs.conquest_strength == 17, "load restores economy")
	ok(_armies_snapshot(gs) == asnap, "armies restored exactly from save")
	var owners_ok := true
	for t in gs.conquest_territories():
		if String(gs.conquest_owner.get(t.id, "")) != String(owners.get(t.id, "")): owners_ok = false
	ok(owners_ok, "ownership restored from save")
	gs.delete_conquest_save()

	# --- Roster carry: survivors bank back into the fielding army ---
	gs.start_conquest(qid)
	gs.begin_conquest_attack("r_cap")   # fielding army blue#0
	gs.capture_roster([FakeUnit.new("musketeers", 6, 2), FakeUnit.new("pikemen", 3, 1)])
	ok(gs.army_by_id("blue#0").get("roster", []).size() == 2, "survivors banked into the fielding army")

	# --- Two-stage order via the map UI: click own army, then click a move target ---
	gs.start_conquest(qid)
	var amap = load("res://scenes/conquest_map.tscn").instantiate()
	root.add_child(amap)
	await process_frame
	amap._on_territory_clicked("b_cap")
	ok(amap.selected_army_id == "blue#0", "clicking an army-tile picks that army")
	amap._on_territory_clicked("b_mine")   # adjacent own empty tile -> move order
	ok(gs.army_by_id("blue#0").get("location", "") == "b_mine", "clicking a move target relocates the picked army")
	amap.queue_free()
	await process_frame

	# --- Historical per-power starting resources (grand_europe) ---
	gs.start_conquest("grand_europe")
	ok(gs.conquest_strength == 4, "France opens with its historical war-chest")
	ok(int(gs.conquest_treasury.get("ottoman", 0)) == 4, "the Ottoman AI opens with its war-chest")
	ok(int(gs.conquest_treasury.get("russia", 0)) == 2, "poorer Russia opens with a smaller war-chest")
	ok(gs.conquest_income_for("ottoman") > gs.conquest_income_for("russia"),
		"a richer economy out-earns a poorer one each round")

	# --- Era-seeded tech tree (player-only, conquest-scoped) ---
	var global_before: int = gs.unlocked_techs.size()
	gs.start_conquest("grand_europe", 1631)   # Thirty Years' War era
	ok(gs.conquest_start_year == 1631, "conquest records its start era")
	ok(gs.tech_unlocked("corned_powder") and gs.tech_unlocked("field_gunnery"),
		"era seeds all tech at/before the start year for free")
	ok(not gs.tech_unlocked("flintlock_musket") and not gs.tech_unlocked("combined_arms"),
		"later-era tech is NOT pre-unlocked")
	ok(gs.tech_mods_for("musketeers")["attack"] >= 2,
		"seeded conquest tech buffs the player's units (corned_powder + volley_fire)")
	var res0: int = gs.conquest_research
	gs.advance_conquest_round()
	ok(gs.conquest_research > res0, "the player earns research each round")
	# Research forward: combined_arms needs field_gunnery + cavalry_doctrine (both seeded).
	gs.conquest_research = 99
	ok(gs.tech_can_unlock("combined_arms"), "a prereq-met later tech becomes researchable")
	ok(gs.unlock_tech("combined_arms"), "unlock spends conquest research")
	ok(gs.conquest_research == 94, "conquest research pool paid the cost (5)")
	ok("combined_arms" in gs.conquest_techs, "the tech joins the conquest set")
	ok(gs.unlocked_techs.size() == global_before, "conquest research never touches the global tech set")
	# Tech state survives a save/load round-trip.
	gs.save_conquest()
	gs.clear_conquest()
	ok(gs.load_conquest(), "conquest with tech state reloads")
	ok(gs.conquest_start_year == 1631 and "combined_arms" in gs.conquest_techs,
		"era + researched tech restored from save")

	# --- Research model: natural (main) + building (academy) + focus ---
	gs.start_conquest("grand_europe", 1631)
	var nat: int = gs._conquest_natural_research()
	ok(gs._conquest_research_income() == nat, "no-focus income = natural + academy(0)")
	gs.conquest_strength = 30
	ok(gs.develop("academy") and gs.conquest_academy == 1, "academy building levels up")
	ok(gs._conquest_research_income() == nat + 1, "the academy adds a small research bonus")
	# Focus: one at a time, greatly boosts the rate, discounts its own branch.
	ok(gs.conquest_focus == "", "no focus at start")
	gs.set_conquest_focus("artillery")
	ok(gs.conquest_focus == "artillery", "a focus can be set")
	ok(gs._conquest_research_income() == nat + 1 + nat, "an active focus roughly doubles the natural rate")
	ok(gs.tech_cost("regimental_guns") == 3 and gs.tech_cost("flintlock_musket") == 4,
		"focus discounts its own branch (artillery -1), not others")
	gs.set_conquest_focus("cavalry")
	ok(gs.conquest_focus == "cavalry" and gs.tech_cost("regimental_guns") == 4,
		"switching focus is exclusive (artillery discount gone)")
	gs.set_conquest_focus("bogus")
	ok(gs.conquest_focus == "", "an invalid focus clears it")
	gs.set_conquest_focus("artillery")
	gs.save_conquest(); gs.clear_conquest(); gs.load_conquest()
	ok(gs.conquest_academy == 1 and gs.conquest_focus == "artillery",
		"academy + focus restored from save")

	# --- Map builds + drives ---
	gs.start_conquest("continental")
	var map = load("res://scenes/conquest_map.tscn").instantiate()
	root.add_child(map)
	await process_frame
	await process_frame
	ok(map.get_child_count() > 0 and map.get_node("HUD").get_child_count() > 0, "conquest map builds")
	var round0 = gs.conquest_round
	map._end_turn()
	await process_frame
	ok(gs.conquest_round == round0 + 1, "End Turn advances the round")
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
