extends Control

# Tech tree screen — a visual branching DAG: four branch columns (infantry /
# cavalry / artillery / support) laid out by year, with connector lines drawn
# from each tech to its prerequisites. Context-aware: inside a conquest it
# shows/spends that game's OWN era-seeded research (and a research focus),
# returning to the map; otherwise it drives the global/campaign tech set.
# Built at runtime so the scene file stays a bare Control.

const COLS := ["infantry", "cavalry", "artillery", "support"]
const COL_NAMES := {"infantry": "步兵", "cavalry": "騎兵", "artillery": "砲兵", "support": "支援"}
const FOCUS_NAMES := {"infantry": "步兵", "cavalry": "騎兵", "artillery": "砲兵", "support": "支援"}
const COL_W := 300
const NODE_W := 264
const NODE_H := 58
const ROW_H := 82
const HEADER_H := 30

var _conquest: bool = false
var _points_label: Label
var _focus_row: HBoxContainer
var _tree_host: Control

# Inner canvas that draws the prerequisite connector lines behind the nodes.
class TreeLines:
	extends Control
	var edges: Array = []   # each: [Vector2 from, Vector2 to, Color]
	func _draw() -> void:
		for e in edges:
			draw_line(e[0], e[1], e[2], 3.0, true)

func _ready() -> void:
	_conquest = GameState.in_conquest()

	var bg := ColorRect.new()
	bg.color = Color(0.08, 0.09, 0.11)
	bg.anchor_right = 1.0
	bg.anchor_bottom = 1.0
	add_child(bg)

	var margin := MarginContainer.new()
	margin.anchor_right = 1.0
	margin.anchor_bottom = 1.0
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 24)
	add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "科技樹 · %d 年起" % GameState.conquest_start_year if _conquest else "科技樹"
	title.add_theme_font_size_override("font_size", 28)
	vbox.add_child(title)

	_points_label = Label.new()
	_points_label.add_theme_font_size_override("font_size", 19)
	vbox.add_child(_points_label)

	var hint := Label.new()
	if _conquest:
		hint.text = "四大分支縱向依年代排列,連線為前置需求。以所選年代之前的科技開局,靠研究點沿樹往 18 世紀推進。"
	else:
		hint.text = "四大分支縱向依年代排列,連線為前置需求。每場勝利獲得研發點數(全域共用),解鎖為相應兵種提供永久加成。"
	hint.add_theme_font_size_override("font_size", 13)
	hint.modulate = Color(0.75, 0.78, 0.82)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(hint)

	# Research focus selector (conquest only) — one specialization at a time.
	if _conquest:
		_focus_row = HBoxContainer.new()
		_focus_row.add_theme_constant_override("separation", 6)
		vbox.add_child(_focus_row)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	_tree_host = Control.new()
	scroll.add_child(_tree_host)

	var back := Button.new()
	var dest := "res://scenes/main_menu.tscn"
	if _conquest:
		back.text = "返回征服地圖"
		dest = "res://scenes/conquest_map.tscn"
	elif GameState.in_campaign():
		back.text = "返回整備室"
		dest = "res://scenes/lounge.tscn"
	else:
		back.text = "返回主選單"
	back.custom_minimum_size = Vector2(0, 42)
	back.pressed.connect(func(): get_tree().change_scene_to_file(dest))
	vbox.add_child(back)

	_rebuild()

func _rebuild() -> void:
	var pool := GameState.research_pool()
	if _conquest:
		_points_label.text = "研究點數:%d(每回合 +%d)" % [pool, GameState._conquest_research_income()]
		_rebuild_focus_row()
	else:
		_points_label.text = "研發點數:%d" % pool

	for c in _tree_host.get_children():
		c.queue_free()

	# Assign techs to branch columns, each sorted by year (top -> bottom).
	var by_col := {}
	for col in COLS:
		by_col[col] = []
	for tid in DataLoader.techs.keys():
		var col := String(DataLoader.techs[tid].get("branch", "support"))
		if not by_col.has(col):
			col = "support"
		by_col[col].append(String(tid))
	for col in COLS:
		by_col[col].sort_custom(func(a, b):
			var ya := int(DataLoader.techs[a].get("year", 0))
			var yb := int(DataLoader.techs[b].get("year", 0))
			return ya < yb if ya != yb else String(a) < String(b))

	# Node rectangles keyed by tech id.
	var rect := {}
	var max_rows := 1
	for ci in range(COLS.size()):
		var col: String = COLS[ci]
		var x: float = ci * COL_W + (COL_W - NODE_W) * 0.5
		for i in range((by_col[col] as Array).size()):
			var tid: String = by_col[col][i]
			rect[tid] = Rect2(x, HEADER_H + i * ROW_H, NODE_W, NODE_H)
		max_rows = maxi(max_rows, (by_col[col] as Array).size())

	var canvas_size := Vector2(COLS.size() * COL_W, HEADER_H + max_rows * ROW_H + 16)
	_tree_host.custom_minimum_size = canvas_size

	# Connector lines (drawn first, behind the nodes).
	var lines := TreeLines.new()
	lines.custom_minimum_size = canvas_size
	lines.size = canvas_size
	lines.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var edges: Array = []
	for tid in rect.keys():
		for req in DataLoader.techs[tid].get("requires", []):
			if not rect.has(req):
				continue
			var a: Rect2 = rect[req]
			var b: Rect2 = rect[tid]
			var col_line := Color(0.45, 0.75, 0.5, 0.9) if GameState.tech_unlocked(String(req)) else Color(0.5, 0.5, 0.55, 0.7)
			edges.append([a.position + Vector2(a.size.x * 0.5, a.size.y), b.position + Vector2(b.size.x * 0.5, 0), col_line])
	lines.edges = edges
	_tree_host.add_child(lines)

	# Column headers.
	var font := ThemeDB.fallback_font
	for ci in range(COLS.size()):
		var hdr := Label.new()
		hdr.text = String(COL_NAMES[COLS[ci]])
		hdr.add_theme_font_size_override("font_size", 17)
		hdr.modulate = Color(0.95, 0.85, 0.5)
		hdr.position = Vector2(ci * COL_W + (COL_W - NODE_W) * 0.5, 0)
		_tree_host.add_child(hdr)

	# Nodes.
	for tid in rect.keys():
		var t: Dictionary = DataLoader.techs[tid]
		var btn := Button.new()
		btn.position = (rect[tid] as Rect2).position
		btn.custom_minimum_size = Vector2(NODE_W, NODE_H)
		btn.size = Vector2(NODE_W, NODE_H)
		btn.add_theme_font_size_override("font_size", 13)
		btn.clip_text = true
		btn.text = _node_text(String(tid), t)
		btn.modulate = _node_color(String(tid), t, pool)
		btn.disabled = not GameState.tech_can_unlock(String(tid))
		var this_id := String(tid)
		btn.pressed.connect(func():
			if GameState.unlock_tech(this_id):
				_rebuild())
		_tree_host.add_child(btn)

func _rebuild_focus_row() -> void:
	for c in _focus_row.get_children():
		c.queue_free()
	var lbl := Label.new()
	lbl.text = "專精:"
	lbl.add_theme_font_size_override("font_size", 14)
	_focus_row.add_child(lbl)
	var opts := [["", "無"]]
	for b in GameState.CONQ_FOCUS_BRANCHES:
		opts.append([b, String(FOCUS_NAMES.get(b, b))])
	for o in opts:
		var fb := Button.new()
		fb.text = ("● " if GameState.conquest_focus == o[0] else "") + String(o[1])
		fb.custom_minimum_size = Vector2(96, 32)
		fb.add_theme_font_size_override("font_size", 14)
		var branch: String = o[0]
		fb.pressed.connect(func():
			GameState.set_conquest_focus(branch)
			_rebuild())
		_focus_row.add_child(fb)

func _node_text(tech_id: String, t: Dictionary) -> String:
	var nm := String(t.get("name", tech_id))
	var year := int(t.get("year", 0))
	var focused: bool = _conquest and GameState.conquest_focus != "" \
		and String(t.get("branch", "")) == GameState.conquest_focus
	var tail := ""
	if GameState.tech_unlocked(tech_id):
		tail = "✓"
	elif not GameState.tech_prereqs_met(tech_id):
		tail = "🔒"
	else:
		tail = "%d點%s" % [GameState.tech_cost(tech_id), ("★" if focused else "")]
	return "%s\n%d · %s" % [nm, year, tail]

func _node_color(tech_id: String, _t: Dictionary, pool: int) -> Color:
	if GameState.tech_unlocked(tech_id):
		return Color(0.6, 0.9, 0.6)          # unlocked
	if not GameState.tech_prereqs_met(tech_id):
		return Color(0.62, 0.62, 0.66)       # locked by prereq
	if GameState.tech_cost(tech_id) > pool:
		return Color(0.92, 0.78, 0.45)       # affordable prereqs, not enough points
	return Color(1, 1, 1)                     # ready to unlock
