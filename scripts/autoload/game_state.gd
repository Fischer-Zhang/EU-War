extends Node

# Autoload singleton (registered as GameState). Holds inter-scene state.

var current_scenario_id: String = ""
var last_result: Dictionary = {}
var difficulty: String = "normal"  # "easy" | "normal" | "hard"

# Campaign state. When campaign_id != "" the player is playing a linked series
# of scenarios; surviving units (with veteran XP/rank) carry into the next one
# via campaign_roster. Empty roster on battle 1 = use the scenario's own force.
var campaign_id: String = ""
var campaign_index: int = 0
var campaign_roster: Array = []   # Array[Dictionary]: {type,name,xp,rank,general}
var browsing_campaigns: bool = false   # select screen mode: campaigns vs scenarios

signal scenario_started(scenario_id: String)
signal scenario_ended(winner: String, summary: Dictionary)

func start_scenario(id: String) -> void:
	current_scenario_id = id
	scenario_started.emit(id)

func end_scenario(winner: String, summary: Dictionary) -> void:
	last_result = {"winner": winner, "summary": summary}
	scenario_ended.emit(winner, summary)

# ------------------------------------------------------------------ campaign

func start_campaign(id: String) -> void:
	campaign_id = id
	campaign_index = 0
	campaign_roster = []
	current_scenario_id = current_campaign_scenario()

func clear_campaign() -> void:
	campaign_id = ""
	campaign_index = 0
	campaign_roster = []

func in_campaign() -> bool:
	return campaign_id != ""

func campaign_scenarios() -> Array:
	return DataLoader.get_campaign(campaign_id).get("scenarios", [])

func current_campaign_scenario() -> String:
	var list := campaign_scenarios()
	if campaign_index >= 0 and campaign_index < list.size():
		return String(list[campaign_index])
	return ""

func advance_campaign() -> void:
	campaign_index += 1
	if not campaign_complete():
		current_scenario_id = current_campaign_scenario()

func campaign_complete() -> bool:
	return campaign_index >= campaign_scenarios().size()

# Snapshot the surviving player units into the roster for the next battle.
func capture_roster(living_player_units: Array) -> void:
	campaign_roster = []
	for u in living_player_units:
		campaign_roster.append({
			"type": u.type_id,
			"name": u.display_name,
			"xp": u.xp,
			"rank": u.rank,
			"general": u.general_id,
		})

# Return a scenario dict whose player units are replaced by the carried roster,
# mapped onto the scenario's own player slot positions (order-preserving). Units
# start at full HP. A no-op when not in a campaign or the roster is empty.
func apply_roster(scenario: Dictionary) -> Dictionary:
	if not in_campaign() or campaign_roster.is_empty():
		return scenario
	var player_faction := ""
	for f in scenario.get("factions", []):
		if String(f.get("controller", "")) == "player":
			player_faction = String(f.get("id", ""))
			break
	if player_faction == "":
		return scenario
	var slots: Array = []
	var new_units: Array = []
	for u in scenario.get("units", []):
		if String(u.get("faction", "")) == player_faction:
			slots.append(u)
		else:
			new_units.append(u)
	var placed := mini(slots.size(), campaign_roster.size())
	for i in range(placed):
		var r: Dictionary = campaign_roster[i]
		new_units.append({
			"faction": player_faction,
			"type": r.get("type", ""),
			"name": r.get("name", ""),
			"at": slots[i].get("at", [0, 0]),
			"xp": int(r.get("xp", 0)),
			"rank": int(r.get("rank", 0)),
			"general": r.get("general", ""),
		})
	if campaign_roster.size() > slots.size():
		push_warning("[Campaign] roster (%d) exceeds scenario player slots (%d); extra veterans benched" % [
			campaign_roster.size(), slots.size()])
	var out := scenario.duplicate(true)
	out["units"] = new_units
	return out
