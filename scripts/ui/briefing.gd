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
	# In a campaign, the player force is the carried roster, not the scenario's
	# default one — reflect that in the order of battle shown here.
	scenario = GameState.apply_roster(scenario)
	title_label.text = String(scenario.get("title", ""))
	era_label.text = String(scenario.get("era", ""))
	body.text = _compose(scenario)
	start_button.grab_focus()

func _campaign_header() -> String:
	if not GameState.in_campaign():
		return ""
	var camp := DataLoader.get_campaign(GameState.campaign_id)
	var total: int = GameState.campaign_scenarios().size()
	return "[b]戰役:%s[/b]  第 %d / %d 場\n\n" % [
		String(camp.get("title", "")), GameState.campaign_index + 1, total]

func _compose(scenario: Dictionary) -> String:
	var lines := []
	if GameState.in_campaign():
		lines.append(_campaign_header())
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
	var secs: Array = scenario.get("secondary_objectives", [])
	if not secs.is_empty():
		lines.append("")
		lines.append("[b]次要目標(選擇性)[/b]")
		for o in secs:
			lines.append("  ◇ %s" % String(o.get("name", "")))
	return "\n".join(lines)

func _on_start_pressed() -> void:
	# Route through the deployment screen (assign generals) before the battle.
	get_tree().change_scene_to_file("res://scenes/deployment.tscn")

func _on_back_pressed() -> void:
	if GameState.in_conquest():
		GameState.cancel_conquest_battle()   # abandon this battle, keep the campaign
		get_tree().change_scene_to_file("res://scenes/conquest_map.tscn")
		return
	if GameState.in_campaign():
		get_tree().change_scene_to_file("res://scenes/lounge.tscn")
		return
	get_tree().change_scene_to_file("res://scenes/scenario_select.tscn")
