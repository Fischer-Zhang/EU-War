extends Control

# Conquest new-game setup: pick the map, the starting ERA (which seeds the
# player's tech level) and the difficulty, then launch. Built at runtime so the
# scene file stays a bare Control. Era anchors span the scenario range
# (1314 -> 18th c.); a later era opens with more of the tech tree already unlocked.

const ERAS := [
	{"year": 1314, "label": "中世紀", "note": "長弓、板甲的時代"},
	{"year": 1500, "label": "文藝復興", "note": "長矛方陣與火繩槍登場"},
	{"year": 1631, "label": "火藥革命", "note": "三十年戰爭:野戰砲兵、齊射"},
	{"year": 1700, "label": "理性時代", "note": "燧發槍、刺刀、線列戰術"},
]

var _map_id: String = ""
var _era_year: int = 1631
var _difficulty: String = "normal"
var _body: VBoxContainer

func _ready() -> void:
	var conqs := DataLoader.conquests.keys()
	_map_id = "grand_europe" if DataLoader.conquests.has("grand_europe") else (String(conqs[0]) if not conqs.is_empty() else "")
	_difficulty = GameState.difficulty

	var bg := ColorRect.new()
	bg.color = Color(0.08, 0.09, 0.11)
	bg.anchor_right = 1.0
	bg.anchor_bottom = 1.0
	add_child(bg)

	var margin := MarginContainer.new()
	margin.anchor_right = 1.0
	margin.anchor_bottom = 1.0
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 32)
	add_child(margin)

	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 10)
	margin.add_child(_body)

	_rebuild()

func _header(text: String, size: int, col: Color = Color(0.92, 0.94, 0.97)) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.modulate = col
	_body.add_child(l)

func _row(labels_values: Array, current, cb: Callable) -> void:
	# labels_values: Array of [display, value]; highlights the one equal to `current`.
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 8)
	for lv in labels_values:
		var val = lv[1]
		var b := Button.new()
		b.text = ("● " if val == current else "") + String(lv[0])
		b.custom_minimum_size = Vector2(0, 40)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", 15)
		b.pressed.connect(func(): cb.call(val))
		hb.add_child(b)
	_body.add_child(hb)

func _rebuild() -> void:
	for c in _body.get_children():
		c.queue_free()

	_header("開始新征服 · 歐陸霸權", 30)
	_header("同一張歐陸大棋盤,劇本由開局年代決定——不同年代有不同的科技起點與歐陸大事件。", 15, Color(0.78, 0.82, 0.88))

	# One unified theater (grand_europe); the era IS the scenario.
	# Era — the tech starting point + era-scoped events.
	_header("開局年代(劇本:科技起點 + 歐陸大事件)", 18)
	for e in ERAS:
		var yr := int(e["year"])
		var seeded: int = GameState._techs_up_to_year(yr).size()
		var total: int = DataLoader.techs.size()
		var mark := "● " if yr == _era_year else ""
		var b := Button.new()
		b.text = "%s%d  %s — %s(起手科技 %d/%d)" % [mark, yr, String(e["label"]), String(e["note"]), seeded, total]
		b.custom_minimum_size = Vector2(0, 42)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.add_theme_font_size_override("font_size", 15)
		b.pressed.connect(func(): _era_year = yr; _rebuild())
		_body.add_child(b)

	# Difficulty.
	_header("難度", 18)
	_row([["簡單", "easy"], ["普通", "normal"], ["困難", "hard"]], _difficulty,
		func(v): _difficulty = v; _rebuild())

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 12)
	_body.add_child(spacer)

	var start := Button.new()
	start.text = "▶ 開始征服"
	start.custom_minimum_size = Vector2(0, 52)
	start.add_theme_font_size_override("font_size", 20)
	start.disabled = _map_id == ""
	start.pressed.connect(_start)
	_body.add_child(start)

	var back := Button.new()
	back.text = "返回主選單"
	back.custom_minimum_size = Vector2(0, 40)
	back.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/main_menu.tscn"))
	_body.add_child(back)

func _start() -> void:
	GameState.clear_campaign()
	GameState.start_conquest(_map_id, _era_year, _difficulty)
	get_tree().change_scene_to_file("res://scenes/conquest_map.tscn")
