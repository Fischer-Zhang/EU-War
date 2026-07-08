extends Control

# Conquest strategic layer with a light economy. Territories on a map coloured by
# owner + adjacency links. Player turn: attack a frontline enemy (gold) -> its
# battle (a win captures it); or spend strength to Muster (global +attack) or
# Fortify an owned frontier region (defenders entrench when held). The enemy then
# counter-attacks a frontier territory (orange) which you must defend. Capturing
# every enemy territory wins. Built at runtime; reloads to refresh after a spend.

const COLOR_PLAYER := Color(0.20, 0.45, 0.75)
const COLOR_SECURED := Color(0.18, 0.55, 0.45)
const COLOR_ENEMY := Color(0.70, 0.25, 0.20)
const COLOR_TARGET := Color(0.85, 0.65, 0.20)
const COLOR_UNDER_ATTACK := Color(0.90, 0.40, 0.15)
const COLOR_LINK := Color(0.5, 0.5, 0.55, 0.7)

func _ready() -> void:
	if not GameState.in_conquest():
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
		return
	var bg := ColorRect.new()
	bg.color = Color(0.09, 0.11, 0.13)
	bg.anchor_right = 1.0
	bg.anchor_bottom = 1.0
	add_child(bg)

	var conq := DataLoader.get_conquest(GameState.conquest_id)
	var counts := GameState.conquest_counts()
	var under_attack := GameState.conquest_enemy_target

	var title := Label.new()
	title.text = String(conq.get("title", "征服"))
	title.add_theme_font_size_override("font_size", 26)
	title.position = Vector2(28, 18)
	add_child(title)

	var status := Label.new()
	status.add_theme_font_size_override("font_size", 16)
	status.position = Vector2(28, 56)
	if GameState.conquest_won():
		status.text = "征服完成!全境已納入版圖。"
		status.modulate = Color(0.5, 0.9, 0.5)
	elif under_attack != "":
		status.text = "⚠ 敵軍反攻「%s」!點擊該地迎戰防守。" % String(GameState.conquest_territory(under_attack).get("name", under_attack))
		status.modulate = Color(0.95, 0.6, 0.35)
	else:
		status.text = "已佔領 %d / %d — 點金色前線進攻,或點己方領地設防。每回合徵收國力。" % [counts.player, counts.total]
	add_child(status)

	# Economy header.
	var econ := Label.new()
	econ.add_theme_font_size_override("font_size", 15)
	econ.position = Vector2(28, 82)
	econ.text = "國力 %d  ·  每回合 +%d  ·  軍備 Lv%d  ·  工業 Lv%d  ·  訓練 Lv%d" % [
		GameState.conquest_strength, GameState.conquest_income(),
		GameState.conquest_army, GameState.conquest_industry, GameState.conquest_training]
	add_child(econ)

	# Row 1: army investments (disabled while defending a counter, like before).
	var busy := (under_attack != "")
	_econ_button("整軍 軍備+1 (費%d)" % GameState.CONQ_MUSTER_COST, Vector2(28, 108), Vector2(180, 30),
		busy or not GameState.can_muster(), _muster)
	_econ_button("工業 收入+1 (費%d)" % GameState.CONQ_INDUSTRY_COST, Vector2(214, 108), Vector2(180, 30),
		busy or not GameState.can_develop("industry"), _develop.bind("industry"))
	_econ_button("訓練所 老兵 (費%d)" % GameState.CONQ_TRAINING_COST, Vector2(400, 108), Vector2(180, 30),
		busy or not GameState.can_develop("training"), _develop.bind("training"))
	_econ_button("返回主選單", Vector2(586, 108), Vector2(130, 30), false, func():
		GameState.clear_conquest()
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn"))

	# Row 2: one-shot pre-battle preparations for the NEXT battle.
	var prep_lbl := Label.new()
	prep_lbl.add_theme_font_size_override("font_size", 14)
	prep_lbl.position = Vector2(28, 144)
	prep_lbl.text = "戰前準備(下場戰鬥生效):"
	prep_lbl.modulate = Color(0.78, 0.82, 0.86)
	add_child(prep_lbl)
	var preps := [
		["recon", "偵察 視野+1"], ["barrage", "砲擊 削弱敵軍"], ["supply", "補給 工事/士氣"]]
	var px := 210
	for p in preps:
		var kind: String = p[0]
		var bought: bool = GameState.prep_active(kind)
		var txt: String = ("✓ " + String(p[1])) if bought else "%s (費%d)" % [String(p[1]), int(GameState.CONQ_PREP_COST[kind])]
		_econ_button(txt, Vector2(px, 140), Vector2(158, 30), bought or not GameState.can_prepare(kind),
			_prepare.bind(kind))
		px += 166

	var vp := get_viewport_rect().size
	var rect := Rect2(Vector2(90, 186), Vector2(vp.x - 180, vp.y - 266))
	var center_of := func(t: Dictionary) -> Vector2:
		return rect.position + Vector2(float(t.get("x", 0.5)) * rect.size.x, float(t.get("y", 0.5)) * rect.size.y)

	var terrs: Array = GameState.conquest_territories()
	var by_id := {}
	for t in terrs:
		by_id[String(t.get("id", ""))] = t

	var drawn := {}
	for t in terrs:
		var a: Vector2 = center_of.call(t)
		for nb in t.get("links", []):
			var ta := String(t.get("id", ""))
			var tb := String(nb)
			var key := (ta + "|" + tb) if ta < tb else (tb + "|" + ta)
			if drawn.has(key) or not by_id.has(tb):
				continue
			drawn[key] = true
			var line := Line2D.new()
			line.width = 3.0
			line.default_color = COLOR_LINK
			line.points = PackedVector2Array([a, center_of.call(by_id[tb])])
			add_child(line)

	for t in terrs:
		var tid := String(t.get("id", ""))
		var owner := String(GameState.conquest_owner.get(tid, "enemy"))
		var is_defense := (tid == under_attack)
		var attackable := (under_attack == "") and GameState.territory_attackable(tid)
		var can_fort := (under_attack == "") and GameState.can_fortify(tid)
		var secured := GameState.conquest_secured.has(tid)
		var fort := GameState.conquest_fortify_level(tid)

		var btn := Button.new()
		btn.custom_minimum_size = Vector2(150, 48)
		btn.size = Vector2(150, 48)
		btn.position = center_of.call(t) - btn.size * 0.5
		btn.add_theme_font_size_override("font_size", 14)

		var label := String(t.get("name", tid))
		if fort > 0:
			label += " 🛡%d" % fort
		var col: Color
		if is_defense:
			label += "  ⚔迎戰"
			col = COLOR_UNDER_ATTACK
		elif attackable:
			label += "  ⚔"
			col = COLOR_TARGET
		elif owner == "player":
			if can_fort:
				label += "  設防 %d" % GameState.CONQ_FORTIFY_COST
			col = COLOR_SECURED if secured else COLOR_PLAYER
		else:
			col = COLOR_ENEMY
		btn.text = label

		btn.add_theme_color_override("font_color", Color.WHITE)
		for st in ["normal", "hover", "pressed", "disabled"]:
			var sb := StyleBoxFlat.new()
			sb.bg_color = col.lightened(0.12) if st == "hover" else col
			sb.set_corner_radius_all(6)
			btn.add_theme_stylebox_override(st, sb)

		if is_defense:
			btn.pressed.connect(_defend)
		elif attackable:
			btn.pressed.connect(_attack.bind(tid))
		elif can_fort:
			btn.pressed.connect(_fortify.bind(tid))
		else:
			btn.disabled = true
		add_child(btn)

	if GameState.conquest_won():
		GameState.clear_conquest()

# Small helper for the economy/prep buttons in the header rows.
func _econ_button(text: String, pos: Vector2, size: Vector2, disabled: bool, cb: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.position = pos
	b.custom_minimum_size = size
	b.add_theme_font_size_override("font_size", 13)
	b.disabled = disabled
	b.pressed.connect(cb)
	add_child(b)

func _develop(track: String) -> void:
	GameState.develop(track)
	get_tree().reload_current_scene()

func _prepare(kind: String) -> void:
	GameState.prepare(kind)
	get_tree().reload_current_scene()

func _attack(tid: String) -> void:
	if GameState.begin_conquest_attack(tid):
		get_tree().change_scene_to_file("res://scenes/briefing.tscn")

func _defend() -> void:
	if GameState.begin_conquest_defense():
		get_tree().change_scene_to_file("res://scenes/briefing.tscn")

func _fortify(tid: String) -> void:
	GameState.fortify(tid)
	get_tree().reload_current_scene()   # refresh the map from updated state

func _muster() -> void:
	GameState.muster()
	get_tree().reload_current_scene()
