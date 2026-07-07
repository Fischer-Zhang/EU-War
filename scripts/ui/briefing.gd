extends Control

@onready var title_label: Label = $Margin/VBox/Title
@onready var era_label: Label = $Margin/VBox/Era
@onready var body: RichTextLabel = $Margin/VBox/Body
@onready var start_button: Button = $Margin/VBox/Buttons/StartButton
@onready var back_button: Button = $Margin/VBox/Buttons/BackButton

func _ready() -> void:
	start_button.pressed.connect(_on_start_pressed)
	back_button.pressed.connect(_on_back_pressed)
	var scenario := DataLoader.get_scenario(GameState.current_scenario_id)
	if scenario.is_empty():
		title_label.text = "(找不到作戰)"
		return
	title_label.text = String(scenario.get("title", ""))
	era_label.text = String(scenario.get("era", ""))
	body.text = _compose(scenario)
	start_button.grab_focus()

func _compose(scenario: Dictionary) -> String:
	var lines := []
	lines.append(String(scenario.get("briefing", "")))
	lines.append("")
	# Faction order of battle.
	var by_faction := {}
	for u in scenario.get("units", []):
		var fid := String(u.get("faction", ""))
		var t := String(u.get("type", ""))
		if not by_faction.has(fid):
			by_faction[fid] = {}
		by_faction[fid][t] = int(by_faction[fid].get(t, 0)) + 1
	var faction_names := {}
	for f in scenario.get("factions", []):
		faction_names[String(f.get("id", ""))] = String(f.get("name", ""))
	for fid in by_faction.keys():
		lines.append("[b]%s[/b]" % faction_names.get(fid, fid))
		var parts := []
		for t in by_faction[fid].keys():
			var def := DataLoader.get_unit_def(t)
			parts.append("%s ×%d" % [String(def.get("name_zh", t)), by_faction[fid][t]])
		lines.append("  " + " · ".join(parts))
	return "\n".join(lines)

func _on_start_pressed() -> void:
	GameState.start_scenario(GameState.current_scenario_id)
	get_tree().change_scene_to_file("res://scenes/battle.tscn")

func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/scenario_select.tscn")
