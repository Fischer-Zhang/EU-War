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

# ------------------------------------------------------------------ deployment / generals

# General assignments chosen on the deployment screen: unit key -> general_id.
# The key is "<type>#<ordinal>" over the player faction's units in scenario
# order, so deployment and battle.gd agree without threading unit identity.
var deploy_generals: Dictionary = {}

func clear_deploy_generals() -> void:
	deploy_generals = {}

# Ordered player-faction units of a (resolved) scenario, each with a stable key.
func player_units_in(scenario: Dictionary) -> Array:
	var pf := ""
	for f in scenario.get("factions", []):
		if String(f.get("controller", "")) == "player":
			pf = String(f.get("id", ""))
			break
	var out: Array = []
	var counts := {}
	for u in scenario.get("units", []):
		if String(u.get("faction", "")) != pf:
			continue
		var t := String(u.get("type", ""))
		var n := int(counts.get(t, 0))
		counts[t] = n + 1
		out.append({
			"key": "%s#%d" % [t, n],
			"type": t,
			"name": String(u.get("name", "")),
			"general": String(u.get("general", "")),
		})
	return out

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

# ------------------------------------------------------------------ conquest

var conquest_id: String = ""
var conquest_owner: Dictionary = {}       # territory_id -> "player" | "enemy"
var conquest_secured: Dictionary = {}     # territory_id -> true (held off a counter)
var conquest_battle: Dictionary = {}      # current battle {territory, defense:bool}
var conquest_enemy_target: String = ""    # queued enemy counter-attack to defend
# Strategic economy: owned territories earn strength each round, spent on a
# global army level (+attack in battles) or fortifying frontier regions
# (defenders entrench when you hold them).
const CONQ_START_STRENGTH := 3
const CONQ_MUSTER_COST := 4
const CONQ_FORTIFY_COST := 2
const CONQ_ARMY_MAX := 3
const CONQ_FORTIFY_MAX := 3
var conquest_strength: int = 0
var conquest_fortify: Dictionary = {}     # territory_id -> fortify level
var conquest_army: int = 0

func start_conquest(id: String) -> void:
	conquest_id = id
	conquest_owner = {}
	conquest_secured = {}
	conquest_battle = {}
	conquest_enemy_target = ""
	conquest_strength = CONQ_START_STRENGTH
	conquest_fortify = {}
	conquest_army = 0
	for t in conquest_territories():
		conquest_owner[String(t.get("id", ""))] = String(t.get("owner", "enemy"))

func clear_conquest() -> void:
	conquest_id = ""
	conquest_owner = {}
	conquest_secured = {}
	conquest_battle = {}
	conquest_enemy_target = ""
	conquest_strength = 0
	conquest_fortify = {}
	conquest_army = 0

func in_conquest() -> bool:
	return conquest_id != ""

func conquest_territories() -> Array:
	return DataLoader.get_conquest(conquest_id).get("territories", [])

func conquest_territory(tid: String) -> Dictionary:
	for t in conquest_territories():
		if String(t.get("id", "")) == tid:
			return t
	return {}

# Effective (undirected) neighbours of a territory — own links plus any territory
# that links to it, so asymmetric data still works.
func _conquest_neighbors(tid: String) -> Array:
	var out := {}
	for nb in conquest_territory(tid).get("links", []):
		out[String(nb)] = true
	for other in conquest_territories():
		if tid in other.get("links", []):
			out[String(other.get("id", ""))] = true
	return out.keys()

func _adjacent_owned_by(tid: String, side: String) -> bool:
	for nb in _conquest_neighbors(tid):
		if String(conquest_owner.get(nb, "")) == side:
			return true
	return false

# Enemy-owned AND on the frontline (adjacent to a player-owned territory).
func territory_attackable(tid: String) -> bool:
	if String(conquest_owner.get(tid, "")) != "enemy":
		return false
	return _adjacent_owned_by(tid, "player")

# The enemy's strategic pick: a player-held, battle-bearing frontier territory it
# hasn't been repelled from yet. "" if it has no valid counter-attack.
func _enemy_pick_target() -> String:
	for t in conquest_territories():
		var tid := String(t.get("id", ""))
		if String(conquest_owner.get(tid, "")) != "player":
			continue
		if String(t.get("scenario", "")) == "" or conquest_secured.has(tid):
			continue
		if _adjacent_owned_by(tid, "enemy"):
			return tid
	return ""

func has_enemy_counter() -> bool:
	return conquest_enemy_target != ""

func begin_conquest_attack(tid: String) -> bool:
	if conquest_enemy_target != "" or not territory_attackable(tid):
		return false
	conquest_battle = {"territory": tid, "defense": false}
	current_scenario_id = String(conquest_territory(tid).get("scenario", ""))
	return true

func begin_conquest_defense() -> bool:
	if conquest_enemy_target == "":
		return false
	conquest_battle = {"territory": conquest_enemy_target, "defense": true}
	current_scenario_id = String(conquest_territory(conquest_enemy_target).get("scenario", ""))
	return true

# Apply a finished battle to the strategic map and advance the turn.
func resolve_conquest_battle(player_won: bool) -> void:
	var tid := String(conquest_battle.get("territory", ""))
	var defense: bool = bool(conquest_battle.get("defense", false))
	conquest_battle = {}
	if tid == "":
		return
	if defense:
		if player_won:
			conquest_secured[tid] = true         # repelled the counter — now safe
		else:
			conquest_owner[tid] = "enemy"          # territory retaken
		conquest_enemy_target = ""                 # enemy's turn is spent
	else:
		if player_won:
			conquest_owner[tid] = "player"
		# A round passed: collect strength, then the enemy queues its counter.
		conquest_strength += conquest_income()
		conquest_enemy_target = _enemy_pick_target()

func conquest_won() -> bool:
	if not in_conquest():
		return false
	for tid in conquest_owner:
		if String(conquest_owner[tid]) == "enemy":
			return false
	return true

func conquest_counts() -> Dictionary:
	var player := 0
	var total := 0
	for tid in conquest_owner:
		total += 1
		if String(conquest_owner[tid]) == "player":
			player += 1
	return {"player": player, "total": total}

# Strength earned per round: one per owned territory.
func conquest_income() -> int:
	var n := 0
	for tid in conquest_owner:
		if String(conquest_owner[tid]) == "player":
			n += 1
	return n

func can_muster() -> bool:
	return in_conquest() and conquest_army < CONQ_ARMY_MAX and conquest_strength >= CONQ_MUSTER_COST

func muster() -> bool:
	if not can_muster():
		return false
	conquest_strength -= CONQ_MUSTER_COST
	conquest_army += 1
	return true

func can_fortify(tid: String) -> bool:
	if not in_conquest() or String(conquest_owner.get(tid, "")) != "player":
		return false
	if String(conquest_territory(tid).get("scenario", "")) == "":
		return false  # the home base has no battle to fortify
	return int(conquest_fortify.get(tid, 0)) < CONQ_FORTIFY_MAX and conquest_strength >= CONQ_FORTIFY_COST

func fortify(tid: String) -> bool:
	if not can_fortify(tid):
		return false
	conquest_strength -= CONQ_FORTIFY_COST
	conquest_fortify[tid] = int(conquest_fortify.get(tid, 0)) + 1
	return true

func conquest_fortify_level(tid: String) -> int:
	return int(conquest_fortify.get(tid, 0))
