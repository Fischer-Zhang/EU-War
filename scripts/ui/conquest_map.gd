extends Control

# Conquest strategic layer. Territories on a map coloured by owner, with adjacency
# links. Player turn: attack a frontline enemy territory (gold) -> its tactical
# battle; a win captures it. The enemy then counter-attacks one of your frontier
# territories (orange) -> you must DEFEND it in battle; win secures it, loss loses
# it. Capturing every enemy territory wins. Built at runtime.

const COLOR_PLAYER := Color(0.20, 0.45, 0.75)
const COLOR_SECURED := Color(0.18, 0.55, 0.45)   # held-off-a-counter player land
const COLOR_ENEMY := Color(0.70, 0.25, 0.20)
const COLOR_TARGET := Color(0.85, 0.65, 0.20)     # attackable frontline enemy
const COLOR_UNDER_ATTACK := Color(0.90, 0.40, 0.15)  # your land under enemy assault
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
	title.position = Vector2(28, 20)
	add_child(title)

	var status := Label.new()
	status.add_theme_font_size_override("font_size", 16)
	status.position = Vector2(28, 60)
	if GameState.conquest_won():
		status.text = "征服完成!全境已納入版圖。"
		status.modulate = Color(0.5, 0.9, 0.5)
	elif under_attack != "":
		status.text = "⚠ 敵軍反攻「%s」!點擊該地迎戰防守。" % String(GameState.conquest_territory(under_attack).get("name", under_attack))
		status.modulate = Color(0.95, 0.6, 0.35)
	else:
		status.text = "已佔領 %d / %d 領地 — 點擊金色(前線)敵領地發動進攻。" % [counts.player, counts.total]
	add_child(status)

	var back := Button.new()
	back.text = "返回主選單"
	back.position = Vector2(28, 88)
	back.custom_minimum_size = Vector2(140, 34)
	back.pressed.connect(func():
		GameState.clear_conquest()
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn"))
	add_child(back)

	var vp := get_viewport_rect().size
	var rect := Rect2(Vector2(90, 150), Vector2(vp.x - 180, vp.y - 230))
	var center_of := func(t: Dictionary) -> Vector2:
		return rect.position + Vector2(float(t.get("x", 0.5)) * rect.size.x, float(t.get("y", 0.5)) * rect.size.y)

	var terrs: Array = GameState.conquest_territories()
	var by_id := {}
	for t in terrs:
		by_id[String(t.get("id", ""))] = t

	# Adjacency links (each undirected pair once, behind the nodes).
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

	# Territory nodes.
	for t in terrs:
		var tid := String(t.get("id", ""))
		var owner := String(GameState.conquest_owner.get(tid, "enemy"))
		var is_defense := (tid == under_attack)
		var attackable := (under_attack == "") and GameState.territory_attackable(tid)
		var secured := GameState.conquest_secured.has(tid)

		var btn := Button.new()
		btn.custom_minimum_size = Vector2(140, 46)
		btn.size = Vector2(140, 46)
		btn.position = center_of.call(t) - btn.size * 0.5
		btn.add_theme_font_size_override("font_size", 15)

		var label := String(t.get("name", tid))
		var col: Color
		if is_defense:
			label += "  ⚔迎戰"
			col = COLOR_UNDER_ATTACK
		elif attackable:
			label += "  ⚔"
			col = COLOR_TARGET
		elif owner == "player":
			if secured:
				label += "  🛡"
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
			btn.disabled = false
			btn.pressed.connect(_defend)
		elif attackable:
			btn.disabled = false
			btn.pressed.connect(_attack.bind(tid))
		else:
			btn.disabled = true
		add_child(btn)

func _attack(tid: String) -> void:
	if GameState.begin_conquest_attack(tid):
		get_tree().change_scene_to_file("res://scenes/briefing.tscn")

func _defend() -> void:
	if GameState.begin_conquest_defense():
		get_tree().change_scene_to_file("res://scenes/briefing.tscn")
