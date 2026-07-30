extends Control

# Tech tree screen. Lists every technology grouped by era with its cost, effect
# and prerequisites; unlocking spends research points. Context-aware: inside a
# conquest it shows/spends that game's OWN era-seeded research (returning to the
# map); otherwise it drives the global/campaign tech set. Built at runtime so the
# scene file stays a bare Control.

var _points_label: Label
var _list: VBoxContainer
var _conquest: bool = false

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
		margin.add_theme_constant_override(side, 28)
	add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "科技研發 · %d 年起" % GameState.conquest_start_year if _conquest else "科技研發"
	title.add_theme_font_size_override("font_size", 30)
	vbox.add_child(title)

	_points_label = Label.new()
	_points_label.add_theme_font_size_override("font_size", 20)
	vbox.add_child(_points_label)

	var hint := Label.new()
	if _conquest:
		hint.text = "征服每回合累積研究點數(本局專屬)。你以所選年代之前的科技開局,沿科技樹往 18 世紀推進;解鎖為相應兵種提供永久加成,於你親臨的戰鬥生效。"
	else:
		hint.text = "任何模式的每場勝利都獲得研發點數(全域共用、自動存檔)。解鎖科技為全軍相應兵種提供永久加成,於所有模式生效。"
	hint.add_theme_font_size_override("font_size", 14)
	hint.modulate = Color(0.75, 0.78, 0.82)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(hint)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)

	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 8)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list)

	var back := Button.new()
	# Return to wherever we came from: conquest map, campaign lounge, or main menu.
	var dest := "res://scenes/main_menu.tscn"
	if _conquest:
		back.text = "返回征服地圖"
		dest = "res://scenes/conquest_map.tscn"
	elif GameState.in_campaign():
		back.text = "返回整備室"
		dest = "res://scenes/lounge.tscn"
	else:
		back.text = "返回主選單"
	back.custom_minimum_size = Vector2(0, 44)
	back.pressed.connect(func(): get_tree().change_scene_to_file(dest))
	vbox.add_child(back)

	_rebuild()

func _rebuild() -> void:
	var pool := GameState.research_pool()
	_points_label.text = "研究點數:%d" % pool if _conquest else "研發點數:%d" % pool
	for c in _list.get_children():
		c.queue_free()
	# Techs sorted by year, with an era header inserted whenever the era changes.
	var ids := DataLoader.techs.keys()
	ids.sort_custom(func(a, b):
		var ya := int(DataLoader.techs[a].get("year", 0))
		var yb := int(DataLoader.techs[b].get("year", 0))
		return ya < yb if ya != yb else String(a) < String(b))
	var cur_era := ""
	for tid in ids:
		var tech_id := String(tid)
		var t: Dictionary = DataLoader.techs[tid]
		var era := String(t.get("era", ""))
		if era != cur_era:
			cur_era = era
			var hdr := Label.new()
			hdr.text = "— %s —" % era
			hdr.add_theme_font_size_override("font_size", 17)
			hdr.modulate = Color(0.95, 0.85, 0.5)
			_list.add_child(hdr)
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(0, 54)
		btn.add_theme_font_size_override("font_size", 16)
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.clip_text = true
		btn.text = _tech_line(tech_id, t, pool)
		btn.disabled = not GameState.tech_can_unlock(tech_id)
		btn.pressed.connect(func():
			if GameState.unlock_tech(tech_id):
				_rebuild())
		_list.add_child(btn)

func _tech_line(tech_id: String, t: Dictionary, pool: int) -> String:
	var nm := String(t.get("name", tech_id))
	var desc := String(t.get("desc", ""))
	var cost := int(t.get("cost", 0))
	var year := int(t.get("year", 0))
	var status := ""
	if GameState.tech_unlocked(tech_id):
		status = "✓ 已解鎖"
	elif not GameState.tech_prereqs_met(tech_id):
		status = "🔒 需前置:%s" % _prereq_names(t)
	elif cost > pool:
		status = "點數不足(需 %d)" % cost
	else:
		status = "解鎖(%d 點)" % cost
	return "%d  %s  —  %s\n%s" % [year, nm, desc, status]

func _prereq_names(t: Dictionary) -> String:
	var names := []
	for req in t.get("requires", []):
		var rt: Dictionary = DataLoader.techs.get(req, {})
		names.append(String(rt.get("name", req)))
	return "、".join(names)
