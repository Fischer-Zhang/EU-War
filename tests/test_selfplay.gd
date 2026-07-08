extends SceneTree

# AI self-play gate + report. Runs headless AI-vs-AI across every combat
# scenario at several difficulty pairings and asserts each battle:
#   * terminates within the turn cap (no infinite loop / stall),
#   * ends with a valid winner faction id or "" (draw),
#   * leaves every living unit on a unique hex, drawn exactly on its coord
#     (stress test for the occupancy + move-sync invariants under full AI play).
# It also prints a win/margin line per battle so the same run doubles as a
# balance/AI-strength report. NOTE: outcomes are dominated by scenario/side
# balance, not difficulty — this gate deliberately does NOT assert a difficulty
# ordering (self-play shows the weight ladder is not monotonic).

const CAP := 50

var fails := 0
var _hc
var _hex_size := 40.0

func ok(cond: bool, msg: String) -> void:
	if not cond:
		fails += 1
		printerr("  FAIL: ", msg)

func _init() -> void:
	_run.call_deferred()

func _sync_ok(b) -> bool:
	var coords := {}
	for u in b.units:
		if not u.is_alive():
			continue
		if coords.has(u.coord):
			return false                 # two living units on one hex
		coords[u.coord] = u
		if u.position.distance_to(_hc.to_pixel(u.coord, _hex_size)) > 0.5:
			return false                 # drawn position drifted from coord
	return true

func _play(sid: String, diffs: Dictionary) -> Dictionary:
	root.get_node("GameState").current_scenario_id = sid
	var b = load("res://scenes/battle.tscn").instantiate()
	b.selfplay_difficulty = diffs
	b.max_turns = CAP
	root.add_child(b)
	var guard := 0
	while not b.battle_over and guard < 20000:
		await process_frame
		guard += 1
	var alive := {}
	for fid in b.factions.keys():
		alive[fid] = b._living_units_of(fid).size()
	var res := {
		"over": b.battle_over,
		"winner": b.winner,
		"valid_winner": b.winner == "" or b.factions.has(b.winner),
		"synced": _sync_ok(b),
		"turns": b.turn_manager.turn_number,
		"alive": alive,
	}
	b.queue_free()
	await process_frame
	return res

func _run() -> void:
	var gs = root.get_node("GameState")
	var dl = root.get_node("DataLoader")
	gs.clear_campaign()
	_hc = load("res://scripts/grid/hex_coord.gd")
	_hex_size = load("res://scripts/grid/hex_map.gd").HEX_SIZE

	var battles := 0
	for s in dl.scenarios:
		var sid := String(s.get("id", ""))
		if sid == "00_tutorial":
			continue
		var fids := []
		for f in s.get("factions", []):
			fids.append(String(f.get("id", "")))
		if fids.size() < 2:
			continue
		for combo in [["hard", "easy"], ["easy", "hard"], ["normal", "normal"]]:
			var diffs := {fids[0]: combo[0], fids[1]: combo[1]}
			var r = await _play(sid, diffs)
			battles += 1
			ok(r.over, "%s %s terminates within %d turns" % [sid, diffs, CAP])
			ok(r.valid_winner, "%s %s produced a valid winner (%s)" % [sid, diffs, r.winner])
			ok(r.synced, "%s %s units stay synced (unique hex + drawn on coord)" % [sid, diffs])
			var win = r.winner if r.winner != "" else "draw"
			print("  %s | %s=%s %s=%s -> %-8s alive=%s t=%d" % [
				sid, fids[0], combo[0], fids[1], combo[1], win, r.alive, r.turns])

	# Defensive-behavior guard: a competent defender with a posture and ranged
	# stand-off must HOLD, not charge out and get wiped (before this fix,
	# AI-england was dead by turn ~5 at Crécy; now it survives).
	var crecy = await _play("02_crecy_1346", {"england": "hard", "france": "easy"})
	ok(crecy.alive.get("england", 0) > 0, "defensive longbows hold at Crécy (not wiped)")
	var poltava = await _play("09_poltava_1709", {"russia": "hard", "sweden": "hard"})
	ok(poltava.alive.get("russia", 0) > 0, "defensive Russian redoubts hold at Poltava")

	print("ran %d self-play battles" % (battles + 2))
	if fails == 0:
		print("test_selfplay: ok")
		quit(0)
	else:
		printerr("test_selfplay: %d failures" % fails)
		quit(1)
