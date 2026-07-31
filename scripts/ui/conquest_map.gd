extends Node2D

# Conquest strategic map (multi-faction). A pannable/zoomable Node2D world
# (MapLayer draws markers+links, Camera pans/zooms) under a fixed CanvasLayer
# HUD. The player commands one power; rival powers expand and fight each other
# via deterministic auto-resolution each round (End Turn). Cities are supply
# points + the elimination objective; a power with no cities is out, and the
# last power standing wins. Battles the player is in play out tactically; the
# rest auto-resolve and are surfaced in the round log.

@onready var map_layer: Node2D = $MapLayer
@onready var camera: Camera2D = $Camera
@onready var hud: CanvasLayer = $HUD

var selected_id: String = ""
var selected_army_id: String = ""   # the player army whose orders are being staged

func _ready() -> void:
	if not GameState.in_conquest():
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
		return
	map_layer.territory_clicked.connect(_on_territory_clicked)
	# Frame the board into the area left of the dock and below the header, so no
	# territory hides under the HUD at the default zoom.
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var usable := Rect2(24, 132, vp.x - 24 - 312, vp.y - 132 - 24)
	var cr: Rect2 = map_layer.content_rect()
	camera.view_rect = usable
	camera.fit_world_rect(cr, usable, 1.0)
	camera.set_content_rect(cr, 140.0)
	# Returning from a battle: re-focus and select the territory just fought over.
	if GameState.conquest_last_fought != "":
		var t := GameState.conquest_territory(GameState.conquest_last_fought)
		if not t.is_empty():
			selected_id = GameState.conquest_last_fought
			selected_army_id = _player_army_at(selected_id)
			camera.focus_on(map_layer.world_pos(t))
			camera.clamp_to_content()
		GameState.conquest_last_fought = ""
	_refresh()

func _on_territory_clicked(tid: String) -> void:
	# Second click of a two-stage order: if an army is picked and the clicked tile
	# is one of its legal targets, issue the order there.
	if selected_army_id != "":
		if GameState.can_move_army(selected_army_id, tid):
			GameState.move_army(selected_army_id, tid)
			selected_id = tid
			selected_army_id = _player_army_at(tid)
			_refresh()
			return
		if GameState.can_army_attack(selected_army_id, tid):
			_attack_with(selected_army_id, tid)
			return
	# Otherwise (re)select the tile and pick a player army standing on it, if any.
	selected_id = tid
	selected_army_id = _player_army_at(tid)
	_refresh()

# The id of a not-yet-acted player army on tid (preferred), else any player army
# there, else "" — the army whose orders this tile's selection stages.
func _player_army_at(tid: String) -> String:
	var fallback := ""
	for a in GameState.armies_at(tid):
		if String(a.get("owner", "")) != GameState.player_power_id:
			continue
		if fallback == "":
			fallback = String(a.get("id", ""))
		if not bool(a.get("moved", false)):
			return String(a.get("id", ""))
	return fallback

func _refresh() -> void:
	for c in hud.get_children():
		c.hide()
		c.queue_free()
	_build_hud()
	map_layer.selected_id = selected_id
	map_layer.selected_army_id = selected_army_id
	map_layer.queue_redraw()

# ------------------------------------------------------------------- HUD build

func _label(text: String, pos: Vector2, size: int, color: Color = Color(0.92, 0.94, 0.97)) -> Label:
	var l := Label.new()
	l.text = text
	l.position = pos
	l.add_theme_font_size_override("font_size", size)
	l.modulate = color
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(l)
	return l

func _button(text: String, pos: Vector2, size: Vector2, disabled: bool, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.position = pos
	b.custom_minimum_size = size
	b.size = size
	b.add_theme_font_size_override("font_size", 14)
	b.disabled = disabled
	if not disabled:
		b.pressed.connect(cb)
	hud.add_child(b)
	return b

func _panel(rect: Rect2, block: bool = true) -> Panel:
	var p := Panel.new()
	p.position = rect.position
	p.custom_minimum_size = rect.size
	p.size = rect.size
	p.mouse_filter = Control.MOUSE_FILTER_STOP if block else Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.12, 0.15, 0.92)
	sb.set_corner_radius_all(8)
	p.add_theme_stylebox_override("panel", sb)
	hud.add_child(p)
	return p

func _build_hud() -> void:
	var conq := DataLoader.get_conquest(GameState.conquest_id)
	var counts := GameState.conquest_counts()
	var busy := GameState.has_enemy_counter()
	var over := GameState.conquest_over()

	_label(String(conq.get("title", "征服")), Vector2(28, 14), 26)

	# Status line.
	var status := _label("", Vector2(28, 50), 16)
	if GameState.conquest_won():
		status.text = "征服完成!你是最後屹立的強權。"
		status.modulate = Color(0.5, 0.9, 0.5)
	elif GameState.conquest_lost():
		status.text = "帝國覆滅——你失去了所有城市。"
		status.modulate = Color(0.95, 0.45, 0.45)
	elif busy:
		status.text = "⚠ 敵軍反攻!點橙圈城市迎戰(可能有多處)。"
		status.modulate = Color(0.95, 0.6, 0.35)
	else:
		status.text = "第 %d 回合 · 城市 %d / %d · 存活強權 %d — 點金圈進攻,點己方城市設防,「結束回合」讓列強行動。" % [
			GameState.conquest_round, int(counts.get("player_cities", 0)),
			_total_cities(), int(counts.get("powers_alive", 0))]

	# Economy readout.
	var focus_names := {"infantry": "步兵", "cavalry": "騎兵", "artillery": "砲兵", "support": "支援"}
	var focus_txt: String = String(focus_names.get(GameState.conquest_focus, "無"))
	_label("資源 %d  ·  每回合 +%d  ·  軍隊 %d  ·  工業 Lv%d  ·  研究院 Lv%d  ·  %d年 · 研究 %d(專精:%s)" % [
		GameState.conquest_strength, GameState.conquest_income(),
		GameState.armies_of(GameState.player_power_id).size(),
		GameState.conquest_industry, GameState.conquest_academy,
		GameState.conquest_start_year, GameState.conquest_research, focus_txt],
		Vector2(28, 80), 15, Color(0.82, 0.86, 0.9))

	_build_standings(Vector2(28, 106))
	_build_difficulty(Vector2(984, 20))
	# Tech tree entry (opens in conquest context; returns to this map).
	_button("科技樹 ▸", Vector2(984, 46), Vector2(140, 28), over, func():
		GameState.save_conquest()
		get_tree().change_scene_to_file("res://scenes/tech_screen.tscn"))
	_build_round_log(Vector2(28, 470))
	_build_dock(busy, over)

	# Back to menu.
	_button("返回主選單", Vector2(28, 682), Vector2(130, 30), false, func():
		GameState.clear_conquest()
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn"))

	if over:
		_build_result_overlay()

func _total_cities() -> int:
	var n := 0
	for pcnt in GameState.conquest_power_counts().values():
		n += int(pcnt.get("cities", 0))
	return n

func _build_standings(pos: Vector2) -> void:
	var pcounts := GameState.conquest_power_counts()
	var x := pos.x
	for p in GameState.conquest_powers:
		var pid := String(p.get("id", ""))
		var info: Dictionary = pcounts.get(pid, {})
		var elim: bool = bool(info.get("eliminated", false))
		var truce := ("☮%d" % GameState.truce_rounds(pid)) if GameState.at_truce(pid) else ""
		var chip := _label("%s %d/%d%s%s" % [
			String(p.get("name", pid)), int(info.get("territories", 0)),
			int(info.get("cities", 0)), ("✗" if elim else ""), truce],
			Vector2(x, pos.y), 14)
		var col := Color(String(p.get("color", "#888888")))
		chip.modulate = col.darkened(0.4) if elim else col
		x += 128.0

func _build_difficulty(pos: Vector2) -> void:
	# The rival powers' AI difficulty is chosen on the setup screen, then locked in.
	var names := {"easy": "簡單", "normal": "普通", "hard": "困難"}
	_label("難度:%s" % String(names.get(GameState.conquest_difficulty, GameState.conquest_difficulty)),
		pos, 14, Color(0.8, 0.83, 0.88))

func _offer_truce(pid: String) -> void:
	GameState.offer_truce(pid)
	_refresh()

func _build_round_log(pos: Vector2) -> void:
	var y := pos.y
	# Historical event banner (if one fired last round).
	var evt: Dictionary = GameState.conquest_last_event
	if not evt.is_empty():
		_label("★ %s:%s" % [String(evt.get("name", "")), String(evt.get("text", ""))],
			Vector2(pos.x, y), 14, Color(0.95, 0.85, 0.45))
		y += 26
	var log_lines: Array = GameState.conquest_last_round_log
	if log_lines.is_empty():
		return
	_label("上回合列強動向", Vector2(pos.x, y), 15, Color(0.8, 0.83, 0.88))
	y += 24
	var shown := 0
	for e in log_lines:
		if shown >= 8:
			break
		shown += 1
		var pid := String(e.get("power", ""))
		var pname := String(GameState.conquest_power(pid).get("name", pid))
		var tname := String(GameState.conquest_territory(String(e.get("territory", ""))).get("name", ""))
		var line := ""
		if String(e.get("kind", "")) == "attack_player":
			line = "%s 反攻你的「%s」——需迎戰" % [pname, tname]
		else:
			line = "%s %s「%s」" % [pname, ("併吞" if bool(e.get("won", false)) else "受挫於"), tname]
		var lbl := _label(line, Vector2(pos.x, y), 13, Color(0.78, 0.8, 0.84))
		lbl.modulate = Color(String(GameState.conquest_power(pid).get("color", "#888888")))
		y += 20

func _build_dock(busy: bool, over: bool) -> void:
	var dock := Rect2(Vector2(978, 66), Vector2(288, 646))
	_panel(dock)
	var x := dock.position.x + 14
	var y := dock.position.y + 12
	var bw := Vector2(260, 30)

	if selected_id != "":
		var t := GameState.conquest_territory(selected_id)
		var owner := String(GameState.conquest_owner.get(selected_id, GameState.NEUTRAL))
		var owner_name := String(GameState.conquest_power(owner).get("name", owner))
		var ttype := "城市" if String(t.get("type", "city")) == "city" else "資源"
		_label(String(t.get("name", selected_id)), Vector2(x, y), 20); y += 30
		_label("%s · %s" % [ttype, owner_name], Vector2(x, y), 14, Color(0.8, 0.83, 0.88)); y += 24
		if String(t.get("type", "city")) != "city":
			_label("每回合 +%d 資源" % int(t.get("yield", GameState.RESOURCE_DEFAULT_YIELD)), Vector2(x, y), 13, Color(0.75, 0.8, 0.7)); y += 22
		var fort := GameState.conquest_fortify_level(selected_id)
		var supplied := GameState.territory_supplied(selected_id)
		_label("工事 %d · %s" % [fort, ("有補給" if supplied else "斷補")], Vector2(x, y), 13,
			Color(0.75, 0.8, 0.7) if supplied else Color(0.85, 0.6, 0.45)); y += 26

		# Picked-army panel: strength, veterans, and what it can do this round.
		if selected_army_id != "":
			var army := GameState.army_by_id(selected_army_id)
			if not army.is_empty():
				var acted: bool = bool(army.get("moved", false))
				var vets: int = (army.get("roster", []) as Array).size()
				_label("我軍 · 兵力 %d/%d%s" % [int(army.get("strength", 1)),
					GameState.CONQ_ARMY_STR_MAX, ("  ·  老兵 %d" % vets) if vets > 0 else ""],
					Vector2(x, y), 14, Color(0.85, 0.9, 0.7)); y += 22
				if acted:
					_label("本回合已行動", Vector2(x, y), 13, Color(0.7, 0.72, 0.75)); y += 22
				elif _army_has_orders(selected_army_id):
					_label("點高亮鄰格:藍=移動 橙=進攻", Vector2(x, y), 13, Color(0.7, 0.8, 0.9)); y += 22
				else:
					_label("無相鄰目標(可原地駐守)", Vector2(x, y), 13, Color(0.72, 0.74, 0.78)); y += 22
		y += 4

		# Context actions for the selected territory.
		if not over:
			if _pending_has(selected_id):
				_button("⚔ 迎戰防守", Vector2(x, y), bw, false, _defend); y += 38
			elif GameState.territory_attackable(selected_id):
				_button("⚔ 進攻此地", Vector2(x, y), bw, false, _attack.bind(selected_id)); y += 38
			elif owner == GameState.player_power_id and GameState.can_fortify(selected_id):
				_button("設防 (費%d)" % GameState.CONQ_FORTIFY_COST, Vector2(x, y), bw, false, _fortify.bind(selected_id)); y += 38
			# Diplomacy with a rival power (independent of the attack option).
			if owner != GameState.player_power_id and owner != GameState.NEUTRAL:
				if GameState.at_truce(owner):
					_label("停戰中(%d 回合)" % GameState.truce_rounds(owner), Vector2(x, y), 14, Color(0.7, 0.85, 0.7)); y += 26
				elif GameState.can_offer_truce(owner):
					_button("提議停戰 (費%d)" % GameState.CONQ_TRUCE_COST, Vector2(x, y), bw, false, _offer_truce.bind(owner)); y += 38
	else:
		_label("點選一塊領地", Vector2(x, y), 16, Color(0.75, 0.78, 0.82)); y += 34

	# Global economy spends (disabled while a defence is pending).
	y = dock.position.y + 196
	_label("國政(城市補給)", Vector2(x, y), 14, Color(0.8, 0.83, 0.88)); y += 26
	_button("整軍 軍備+1 (費%d)" % GameState.CONQ_MUSTER_COST, Vector2(x, y), bw,
		busy or not GameState.can_muster(), _muster); y += 34
	_button("工業 收入+1 (費%d)" % GameState.CONQ_INDUSTRY_COST, Vector2(x, y), bw,
		busy or not GameState.can_develop("industry"), _develop.bind("industry")); y += 34
	_button("訓練所 老兵 (費%d)" % GameState.CONQ_TRAINING_COST, Vector2(x, y), bw,
		busy or not GameState.can_develop("training"), _develop.bind("training")); y += 34
	_button("徵兵 +1 部隊 (費%d)" % GameState.CONQ_RECRUIT_COST, Vector2(x, y), bw,
		busy or not GameState.can_recruit(), _recruit); y += 34
	_button("整補 老兵+1階 (費%d)" % GameState.CONQ_HEAL_COST, Vector2(x, y), bw,
		busy or not GameState.can_heal(), _heal); y += 34
	_button("研究院 研究+1 (費%d)" % GameState.CONQ_ACADEMY_COST, Vector2(x, y), bw,
		busy or not GameState.can_develop("academy"), _develop.bind("academy")); y += 34

	# Pre-battle preparations for the next fight.
	y = dock.position.y + 396
	_label("戰前準備(下場生效)", Vector2(x, y), 14, Color(0.8, 0.83, 0.88)); y += 26
	for kind in ["recon", "barrage", "supply"]:
		var names := {"recon": "偵察 視野+1", "barrage": "砲擊 削弱敵軍", "supply": "補給 工事/士氣"}
		var bought: bool = GameState.prep_active(kind)
		var txt: String = ("✓ " + String(names[kind])) if bought else "%s (費%d)" % [String(names[kind]), int(GameState.CONQ_PREP_COST[kind])]
		_button(txt, Vector2(x, y), bw, bought or not GameState.can_prepare(kind), _prepare.bind(kind)); y += 32

	# End turn.
	_button("結束回合 ▶", Vector2(x, dock.position.y + dock.size.y - 42), bw,
		busy or over, _end_turn)

func _pending_has(tid: String) -> bool:
	for e in GameState.conquest_pending_defenses():
		if String(e.get("territory", "")) == tid \
			and String(GameState.conquest_owner.get(tid, "")) == GameState.player_power_id:
			return true
	return false

func _build_result_overlay() -> void:
	var vp := get_viewport().get_visible_rect().size
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.size = vp
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	hud.add_child(dim)
	var won := GameState.conquest_won()
	var big := _label("征服完成!" if won else "帝國覆滅", Vector2(vp.x * 0.5 - 120, vp.y * 0.5 - 60), 40,
		Color(0.6, 0.95, 0.6) if won else Color(0.95, 0.5, 0.5))
	big.z_index = 1
	var back := _button("返回主選單", Vector2(vp.x * 0.5 - 80, vp.y * 0.5 + 10), Vector2(160, 40), false, func():
		GameState.clear_conquest()
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn"))
	back.z_index = 1

# ------------------------------------------------------------------- actions

func _army_has_orders(army_id: String) -> bool:
	var a := GameState.army_by_id(army_id)
	if a.is_empty() or bool(a.get("moved", false)):
		return false
	for nb in GameState._conquest_neighbors(String(a.get("location", ""))):
		if GameState.can_move_army(army_id, nb) or GameState.can_army_attack(army_id, nb):
			return true
	return false

func _attack(tid: String) -> void:
	if GameState.begin_conquest_attack(tid):
		get_tree().change_scene_to_file("res://scenes/briefing.tscn")

func _attack_with(army_id: String, tid: String) -> void:
	if GameState.begin_conquest_attack(tid, army_id):
		get_tree().change_scene_to_file("res://scenes/briefing.tscn")

func _defend() -> void:
	if GameState.begin_conquest_defense():
		get_tree().change_scene_to_file("res://scenes/briefing.tscn")

func _fortify(tid: String) -> void:
	GameState.fortify(tid)
	_refresh()

func _muster() -> void:
	GameState.muster()
	_refresh()

func _develop(track: String) -> void:
	GameState.develop(track)
	_refresh()

func _recruit() -> void:
	GameState.recruit()
	_refresh()

func _heal() -> void:
	GameState.heal()
	_refresh()

func _prepare(kind: String) -> void:
	GameState.prepare(kind)
	_refresh()

func _end_turn() -> void:
	GameState.advance_conquest_round()
	selected_id = ""
	selected_army_id = ""
	_refresh()
