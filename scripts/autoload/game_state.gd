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

# Tech tree (campaign-only): research points earned from victories are spent to
# unlock army-wide upgrades that add stat modifiers to matching player units.
const RESEARCH_START := 3
const RESEARCH_PER_WIN := 3
var research_points: int = 0
var unlocked_techs: Array = []

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
	research_points = RESEARCH_START
	unlocked_techs = []
	current_scenario_id = current_campaign_scenario()

func clear_campaign() -> void:
	campaign_id = ""
	campaign_index = 0
	campaign_roster = []
	research_points = 0
	unlocked_techs = []

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

# ------------------------------------------------------------------ tech tree

func award_research(points: int) -> void:
	research_points += points

func tech_unlocked(tech_id: String) -> bool:
	return tech_id in unlocked_techs

func tech_prereqs_met(tech_id: String) -> bool:
	var t: Dictionary = DataLoader.techs.get(tech_id, {})
	for req in t.get("requires", []):
		if not (req in unlocked_techs):
			return false
	return true

func tech_can_unlock(tech_id: String) -> bool:
	if tech_id in unlocked_techs:
		return false
	var t: Dictionary = DataLoader.techs.get(tech_id, {})
	if t.is_empty():
		return false
	if int(t.get("cost", 0)) > research_points:
		return false
	return tech_prereqs_met(tech_id)

func unlock_tech(tech_id: String) -> bool:
	if not tech_can_unlock(tech_id):
		return false
	research_points -= int(DataLoader.techs[tech_id].get("cost", 0))
	unlocked_techs.append(tech_id)
	return true

# Aggregate additive stat modifiers from all unlocked techs that apply to a unit
# type. Shape matches CombatModifiers: { attack, defense, vs_armor, move, vision }.
func tech_mods_for(type_id: String) -> Dictionary:
	var out := {"attack": 0, "defense": 0, "vs_armor": 0, "move": 0, "vision": 0}
	for tid in unlocked_techs:
		var t: Dictionary = DataLoader.techs.get(tid, {})
		var applies = t.get("applies_to", "all")
		var matches: bool = (applies is Array and type_id in applies) or (not (applies is Array) and String(applies) == "all")
		if not matches:
			continue
		var m: Dictionary = t.get("mods", {})
		for k in out.keys():
			out[k] += int(m.get(k, 0))
	return out
