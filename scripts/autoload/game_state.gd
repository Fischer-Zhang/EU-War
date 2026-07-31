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

# Side selection — which faction the human controls (the rest become AI). For a
# single battle, player_faction_override names the chosen faction id (""=the
# scenario's default player side). For a campaign, campaign_side picks the
# faction INDEX (0/1) to control across every scenario, so you can play either
# nation's arc (attacker or defender) with your veterans carrying that side.
var player_faction_override: String = ""
var campaign_side: int = 0

# Tech tree (GLOBAL & persistent): research points earned from victories in ANY
# mode (single battle / campaign / conquest) accrue to one shared pool, and
# unlocked upgrades add stat modifiers to matching player units in every mode.
# Both persist to disk (SAVE_PATH) so progression survives app restarts — the
# tree is reachable from the main menu, not tied to a campaign. See
# reference project WorldWarII, which persists progression under user://.
const RESEARCH_START := 3
const RESEARCH_PER_WIN := 3
const PROGRESS_SAVE_PATH := "user://progress.json"
const CONQUEST_SAVE_PATH := "user://conquest_save.json"
const CONQUEST_SAVE_FILE := "conquest_save.json"
var research_points: int = 0
var unlocked_techs: Array = []

signal scenario_started(scenario_id: String)
signal scenario_ended(winner: String, summary: Dictionary)

func _ready() -> void:
	_load_progress()

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
	# The side the human actually commands (honours single-battle / campaign side
	# selection), not just the scenario's declared player faction.
	var pf := resolve_player_faction(scenario)
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

func start_campaign(id: String, side: int = 0) -> void:
	# Research points / unlocked techs are GLOBAL now — a campaign no longer
	# resets them (see the tech-tree section). `side` picks which faction index
	# the player controls across the whole campaign.
	campaign_id = id
	campaign_index = 0
	campaign_roster = []
	campaign_side = side
	player_faction_override = ""
	current_scenario_id = current_campaign_scenario()

func clear_campaign() -> void:
	campaign_id = ""
	campaign_index = 0
	campaign_roster = []
	campaign_side = 0

# The faction the human controls in a scenario, honouring side selection: a
# campaign's chosen faction index, else a single-battle override, else the
# scenario's declared player faction (first controller=="player").
func resolve_player_faction(scenario: Dictionary) -> String:
	var facs: Array = scenario.get("factions", [])
	if facs.is_empty():
		return ""
	if in_campaign():
		var idx: int = clampi(campaign_side, 0, facs.size() - 1)
		return String(facs[idx].get("id", ""))
	if player_faction_override != "":
		for f in facs:
			if String(f.get("id", "")) == player_faction_override:
				return player_faction_override
	# The scenario's default protagonist side (controller "player", else index 0).
	var default_id := String(facs[0].get("id", ""))
	for f in facs:
		if String(f.get("controller", "")) == "player":
			default_id = String(f.get("id", ""))
			break
	# Conquest defence mirrors the sides: when the enemy counter-attacks a
	# territory you hold, you command the OTHER faction, so defending plays as the
	# reverse of the attack that took it — you hold the ground the AI now storms
	# (or sally against its garrison). A fresh battle on the same map, not a
	# replay. Roster/fortify/posture all key off resolve_player_faction, so they
	# follow the swap automatically (the "player defensive -> AI aggressive" flip
	# in battle.gd then makes the AI assault when you man the defensive side).
	if in_conquest() and bool(conquest_battle.get("defense", false)):
		for f in facs:
			if String(f.get("id", "")) != default_id:
				return String(f.get("id", ""))
	return default_id

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
# Bank the surviving player units into the active mode's roster (campaign or
# conquest — the two are mutually exclusive), preserving XP/rank/general.
func capture_roster(living_player_units: Array) -> void:
	var captured: Array = []
	for u in living_player_units:
		captured.append({
			"type": u.type_id,
			"name": u.display_name,
			"xp": u.xp,
			"rank": u.rank,
			"general": u.general_id,
		})
	if in_conquest():
		var fa := _battle_fielding_army()   # survivors bank back into the army that fought
		if not fa.is_empty():
			fa["roster"] = captured
	else:
		campaign_roster = captured

# Return a scenario dict whose player units are replaced by the carried roster,
# mapped onto the scenario's own player slot positions (order-preserving). Units
# start at full HP. A no-op when not in a campaign or the roster is empty.
func apply_roster(scenario: Dictionary) -> Dictionary:
	# The active mode's carried veterans (campaign or conquest); the two modes are
	# mutually exclusive, so at most one roster is live.
	var roster: Array = campaign_roster if in_campaign() else (_active_battle_roster() if in_conquest() else [])
	if roster.is_empty():
		return scenario
	var player_faction := resolve_player_faction(scenario)
	if player_faction == "":
		return scenario
	var slots: Array = []
	var new_units: Array = []
	for u in scenario.get("units", []):
		if String(u.get("faction", "")) == player_faction:
			slots.append(u)
		else:
			new_units.append(u)
	var placed := mini(slots.size(), roster.size())
	for i in range(placed):
		var r: Dictionary = roster[i]
		var slot: Dictionary = slots[i]
		var vet := {
			"faction": player_faction,
			"type": r.get("type", ""),
			"name": r.get("name", ""),
			"at": slot.get("at", [0, 0]),
			"xp": int(r.get("xp", 0)),
			"rank": int(r.get("rank", 0)),
			"general": r.get("general", ""),
		}
		if slot.has("dig_in"):
			vet["dig_in"] = slot["dig_in"]   # veterans inherit the slot's prepared position
		new_units.append(vet)
	# Replenishment: fill any player slots the roster didn't cover with the
	# scenario's own fresh troops. Casualties in one battle never leave you
	# understrength for the next — veterans are a bonus overlay on top of a full
	# force, not a dwindling pool that spirals into an unwinnable battle.
	for i in range(placed, slots.size()):
		new_units.append(slots[i])
	if roster.size() > slots.size():
		push_warning("[Roster] roster (%d) exceeds scenario player slots (%d); extra veterans benched" % [
			roster.size(), slots.size()])
	var out := scenario.duplicate(true)
	out["units"] = new_units
	return out

# Relabel a conquest battle's two factions with the ACTUAL powers fighting over
# the territory (names + colours), so the briefing/battle read e.g. "法蘭西 vs
# 鄂圖曼" instead of the neutral board scenario's own factions. Combat still keys
# off the unchanged faction ids — only the display changes. No-op outside a
# conquest battle. Call after apply_roster.
func apply_conquest_faction_labels(scenario: Dictionary) -> Dictionary:
	if not in_conquest() or conquest_battle.is_empty():
		return scenario
	var pf := resolve_player_faction(scenario)
	var atk := String(conquest_battle.get("attacker", ""))
	var dfd := String(conquest_battle.get("defender", ""))
	var enemy_pid := dfd if atk == player_power_id else atk
	var out := scenario.duplicate(true)
	for f in out.get("factions", []):
		var pid: String = player_power_id if String(f.get("id", "")) == pf else enemy_pid
		var pw := conquest_power(pid)
		if not pw.is_empty():
			f["name"] = String(pw.get("name", f.get("name", "")))
			f["color"] = String(pw.get("color", f.get("color", "")))
	return out

# ------------------------------------------------------------------ tech tree

# Load the global progression pool from disk (or seed a fresh one). Only strings
# and an int are read, so this is safe to call before other autoloads are ready.
func _load_progress() -> void:
	if not FileAccess.file_exists(PROGRESS_SAVE_PATH):
		reset_progress()
		return
	var f := FileAccess.open(PROGRESS_SAVE_PATH, FileAccess.READ)
	if f == null:
		reset_progress()
		return
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(data) != TYPE_DICTIONARY:
		reset_progress()
		return
	research_points = int(data.get("research_points", RESEARCH_START))
	unlocked_techs = []
	for tid in data.get("unlocked_techs", []):
		unlocked_techs.append(String(tid))

func _save_progress() -> void:
	var f := FileAccess.open(PROGRESS_SAVE_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({
		"research_points": research_points,
		"unlocked_techs": unlocked_techs,
	}))
	f.close()

# Reset the global progression to its initial seed (and persist it). Used by a
# "new game"-style reset and by tests that need a known starting state.
func reset_progress() -> void:
	research_points = RESEARCH_START
	unlocked_techs = []
	_save_progress()

func award_research(points: int) -> void:
	research_points += points
	_save_progress()

# Lounge upgrade: spend research points to promote a carried veteran (+1 rank).
const PROMOTE_COST := 4
const ROSTER_RANK_MAX := 3

func can_promote_roster(i: int) -> bool:
	return in_campaign() and i >= 0 and i < campaign_roster.size() \
		and int(campaign_roster[i].get("rank", 0)) < ROSTER_RANK_MAX \
		and research_points >= PROMOTE_COST

func promote_roster_unit(i: int) -> bool:
	if not can_promote_roster(i):
		return false
	research_points -= PROMOTE_COST
	campaign_roster[i]["rank"] = int(campaign_roster[i].get("rank", 0)) + 1
	_save_progress()
	return true

# The tech context in play: a conquest game keeps its OWN unlocked set + research
# pool (seeded by the chosen era), so its research doesn't touch the global/campaign
# progress. Outside conquest these fall through to the global tech state.
func active_techs() -> Array:
	return conquest_techs if in_conquest() else unlocked_techs

func research_pool() -> int:
	return conquest_research if in_conquest() else research_points

func tech_unlocked(tech_id: String) -> bool:
	return tech_id in active_techs()

func tech_prereqs_met(tech_id: String) -> bool:
	var t: Dictionary = DataLoader.techs.get(tech_id, {})
	var techs := active_techs()
	for req in t.get("requires", []):
		if not (req in techs):
			return false
	return true

func tech_can_unlock(tech_id: String) -> bool:
	if tech_id in active_techs():
		return false
	var t: Dictionary = DataLoader.techs.get(tech_id, {})
	if t.is_empty():
		return false
	if tech_cost(tech_id) > research_pool():
		return false
	return tech_prereqs_met(tech_id)

func unlock_tech(tech_id: String) -> bool:
	if not tech_can_unlock(tech_id):
		return false
	var cost := tech_cost(tech_id)
	if in_conquest():
		conquest_research -= cost
		conquest_techs.append(tech_id)
		save_conquest()
	else:
		research_points -= cost
		unlocked_techs.append(tech_id)
		_save_progress()
	return true

# Aggregate additive stat modifiers from all active techs that apply to a unit
# type. Shape matches CombatModifiers: { attack, defense, vs_armor, move, vision }.
func tech_mods_for(type_id: String) -> Dictionary:
	var out := {"attack": 0, "defense": 0, "vs_armor": 0, "move": 0, "vision": 0}
	for tid in active_techs():
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
var conquest_owner: Dictionary = {}       # territory_id -> power id
var conquest_secured: Dictionary = {}     # territory_id -> true (repelled a counter THIS round)
var conquest_battle: Dictionary = {}      # current battle {territory, defense, attacker, defender}
# --- Multi-faction strategic layer ---
# The strategic map hosts several great powers; only the tactical battles stay
# two-sided (attacker vs defender over one contested territory). One power is the
# player; the rest are AI that expand and fight each other via deterministic
# auto-resolution. A power reduced to zero cities is eliminated; the last power
# standing (the player) wins, and the player losing their last city is defeat.
var player_power_id: String = ""
var conquest_powers: Array = []           # [{id,name,color,controller}]
var conquest_defense_queue: Array = []    # [{attacker, territory}] AI attacks on the player
var conquest_eliminated: Dictionary = {}  # power id -> true
var conquest_result: String = ""          # "" | "won" | "lost"
var conquest_round: int = 0
var conquest_treasury: Dictionary = {}    # AI power id -> strength
var conquest_last_round_log: Array = []   # [{power, kind, territory, won}] for the round report
var conquest_last_fought: String = ""     # territory of the last tactical battle (map re-focus)
var conquest_difficulty: String = "normal"  # scales the rival powers' strategic AI
var conquest_truce: Dictionary = {}       # rival power id -> rounds of non-aggression remaining
var conquest_last_event: Dictionary = {}  # the historical event that fired last round (for the UI)
# --- Battlefield armies (positioned units every power moves on the map) ---
var conquest_armies: Array = []           # [{id, owner, location, strength, moved, roster}]
var conquest_army_seq: Dictionary = {}    # power id -> next army sequence number
const NEUTRAL := "neutral"
const CONQ_TRUCE_COST := 4                 # resource cost to broker a truce
const CONQ_TRUCE_ROUNDS := 5               # how many rounds a truce holds
# Historical events: deterministic (keyed off the round, no RNG) and player-only,
# so they add texture to the long game without disturbing the AI-vs-AI balance.
const CONQ_EVENT_CHANCE := 35              # % of rounds that spring an event
const CONQ_EVENTS := [
	{"id": "harvest", "name": "豐收", "kind": "resource", "amount": 4, "text": "風調雨順,國庫充盈(資源 +4)。"},
	{"id": "inheritance", "name": "聯姻繼承", "kind": "resource", "amount": 6, "text": "一紙婚約帶來大筆嫁妝(資源 +6)。"},
	{"id": "volunteers", "name": "志願從軍", "kind": "recruit", "amount": 0, "text": "愛國熱潮為你添一支老練部隊。"},
	{"id": "engineer", "name": "築城名匠", "kind": "fortify", "amount": 0, "text": "一座前線城市加築工事。"},
	{"id": "munitions", "name": "軍火商", "kind": "prep", "prep": "barrage", "amount": 0, "text": "下場戰鬥敵軍開局遭砲擊。"},
	{"id": "spies", "name": "間諜網", "kind": "prep", "prep": "recon", "amount": 0, "text": "下場戰鬥全軍視野 +1。"},
	{"id": "plague", "name": "瘟疫", "kind": "resource", "amount": -4, "text": "瘟疫肆虐,稅收銳減(資源 −4)。"},
	{"id": "revolt", "name": "地方叛亂", "kind": "revolt", "amount": 0, "text": "一塊資源領地脫離掌控。"},
	{"id": "silver", "name": "新大陸白銀", "kind": "resource", "amount": 8, "text": "新大陸白銀運抵,國庫暴增(資源 +8)。"},
	{"id": "famine", "name": "饑荒", "kind": "resource", "amount": -5, "text": "歉收饑荒,民生凋敝(資源 −5)。"},
	{"id": "drillmaster", "name": "名將操練", "kind": "promote", "amount": 0, "text": "名將投效,一支老兵晉升一階。"},
	{"id": "mutiny", "name": "傭兵譁變", "kind": "disband", "amount": 0, "text": "欠餉譁變,一支部隊譁散(失去名冊中最生嫩的一支)。"},
]
# Strategic economy: owned territories earn strength each round, spent on a
# global army level (+attack in battles), fortifying frontier regions (defenders
# entrench when you hold them), development tracks (permanent army-wide edges),
# or one-shot pre-battle preparations that shape the NEXT battle's opening.
const CONQ_START_STRENGTH := 3
const CONQ_MUSTER_COST := 4
const CONQ_FORTIFY_COST := 2
const CONQ_ARMY_MAX := 3
const CONQ_FORTIFY_MAX := 3
# Development tracks (global, permanent): industry lifts strength income; the
# training academy gives units that fight from here a veteran head start.
const CONQ_INDUSTRY_COST := 3
const CONQ_INDUSTRY_MAX := 3
const CONQ_TRAINING_COST := 4
const CONQ_TRAINING_MAX := 2
const CONQ_TRAIN_XP := 3                   # start XP granted per training level
const CONQ_ACADEMY_COST := 4               # research building: +1 research/round per level
const CONQ_ACADEMY_MAX := 3
# Pre-battle preparations (one-shot, consumed by the next battle): recon grants
# army-wide vision, barrage softens the enemy, supply digs your troops in.
const CONQ_PREP_COST := {"recon": 2, "barrage": 3, "supply": 2}
# Multi-faction economy & deterministic auto-resolution tunables.
const CONQ_CITY_BASE := 1                  # income per supplied city
const RESOURCE_DEFAULT_YIELD := 2          # income per supplied resource node (if unspecified)
const CONQ_RECRUIT_COST := 5               # raise a fresh veteran at a supplied city
const CONQ_HEAL_COST := 3                  # reinforce (rank up) the weakest roster unit
const CONQ_ROSTER_MAX := 8
const CONQ_AI_ARMY_COST := 4
const CONQ_AI_ARMY_MAX := 4
# Battlefield-army tunables.
const CONQ_ARMY_STR_MAX := 4               # per-army strength cap
const CONQ_ARMY_START_STR := 1             # strength of a synthesized/raised army
const CONQ_GARRISON_CITY := 3              # standing garrison strength of an army-less city
const CONQ_GARRISON_RESOURCE := 0          # army-less resource nodes fall to any adjacent army
const CONQ_RAISE_COST := 5                 # raise a NEW army at a supplied city
const CONQ_REINFORCE_COST := 4             # +1 strength (and a roster unit) to an army
# Auto-resolve is LOCAL, not empire-wide: a power's strength at a front comes from
# its army level and its territories massed AROUND that front, not its total size.
# This stops the biggest empire steamrolling every border at once (anti-snowball).
const AR_W_ARMY := 2                        # weight of army strength
const AR_W_ADJ := 1                         # weight of own supplied territories adjacent to the front
const AR_W_FORT := 2                        # weight of fortify (defender)
const AR_W_DEFENDER := 2                    # home-defence edge / tie-breaker
const CONQ_ADJ_CAP := 2                     # cap on local adjacency mass (anti-snowball)
# The chosen era seeds the player's tech; research earned per round advances it.
const CONQ_START_YEAR_DEFAULT := 1631       # Thirty Years' War (fallback era)
const CONQ_RESEARCH_PER_ROUND := 2          # base research the player earns each round
var conquest_strength: int = 0
var conquest_fortify: Dictionary = {}     # territory_id -> fortify level
var conquest_industry: int = 0
var conquest_training: int = 0
var conquest_prep: Dictionary = {}        # prep kind -> true, for the pending battle
var conquest_start_year: int = CONQ_START_YEAR_DEFAULT  # the era the game opened in
var conquest_techs: Array = []            # tech ids unlocked in THIS conquest (player-only)
var conquest_research: int = 0            # research points to spend on the tech tree
var conquest_academy: int = 0             # research building level (+1 research/round each)
var conquest_focus: String = ""           # active research specialization (a branch), one at a time
const CONQ_FOCUS_BRANCHES := ["infantry", "cavalry", "artillery", "support"]

# Start a conquest on map `id`. `start_year` picks the era (seeds the player's
# starting tech); `diff` optionally overrides the difficulty (else inherit global).
func start_conquest(id: String, start_year: int = CONQ_START_YEAR_DEFAULT, diff: String = "") -> void:
	conquest_id = id
	conquest_powers = _load_powers()
	player_power_id = _find_player_power()
	conquest_owner = {}
	conquest_secured = {}
	conquest_battle = {}
	conquest_defense_queue = []
	conquest_eliminated = {}
	conquest_result = ""
	conquest_round = 0
	conquest_treasury = {}
	conquest_last_round_log = []
	conquest_last_fought = ""
	conquest_difficulty = diff if diff != "" else difficulty   # explicit, else global
	conquest_truce = {}
	conquest_last_event = {}
	conquest_strength = _power_start_treasury(player_power_id)
	conquest_fortify = {}
	conquest_industry = 0
	conquest_training = 0
	conquest_prep = {}
	conquest_start_year = start_year
	conquest_techs = _techs_up_to_year(start_year)   # era-appropriate starting tech
	conquest_research = 0
	conquest_academy = 0
	conquest_focus = ""
	player_faction_override = ""   # conquest uses each territory's default sides
	for t in conquest_territories():
		conquest_owner[String(t.get("id", ""))] = String(t.get("owner", NEUTRAL))
	for pid in _ai_powers_in_order():
		conquest_treasury[pid] = _power_start_treasury(pid)
	_synthesize_armies()   # place each power's starting armies on the map
	save_conquest()   # a fresh conquest is immediately resumable

# All tech ids available at or before `year` — the free starting set for an era.
func _techs_up_to_year(year: int) -> Array:
	var out: Array = []
	for tid in DataLoader.techs.keys():
		if int(DataLoader.techs[tid].get("year", 0)) <= year:
			out.append(String(tid))
	return out

# Research the player earns per round, from three sources (per design):
#   natural  (main)  = base + supplied-cities scaling — a bigger realm advances faster
#   building (small) = the research academy level
#   focus    (big)   = an active specialization roughly DOUBLES the natural rate
# Only one focus can be active at a time (conquest_focus).
func _conquest_natural_research() -> int:
	var cities := 0
	for tid in conquest_supplied_for(player_power_id):
		if _is_city(conquest_territory(tid)):
			cities += 1
	@warning_ignore("integer_division")
	var bonus := cities / 3
	return CONQ_RESEARCH_PER_ROUND + bonus

func _conquest_research_income() -> int:
	var natural := _conquest_natural_research()
	var total := natural + conquest_academy          # + building (small)
	if conquest_focus != "":
		total += natural                             # + focus (greatly speeds progress)
	return total

# The cost to unlock a tech, with the active focus discounting its own branch
# (a specialization researches its line faster). Never below 1.
func tech_cost(tech_id: String) -> int:
	var c := int(DataLoader.techs.get(tech_id, {}).get("cost", 0))
	if in_conquest() and conquest_focus != "" \
		and String(DataLoader.techs.get(tech_id, {}).get("branch", "")) == conquest_focus:
		c = maxi(1, c - 1)
	return c

# Set the active research specialization (a branch, or "" for none). One at a time.
func set_conquest_focus(branch: String) -> void:
	if not in_conquest():
		return
	conquest_focus = branch if branch in CONQ_FOCUS_BRANCHES else ""
	save_conquest()

func clear_conquest() -> void:
	conquest_id = ""
	conquest_powers = []
	player_power_id = ""
	conquest_owner = {}
	conquest_secured = {}
	conquest_battle = {}
	conquest_defense_queue = []
	conquest_eliminated = {}
	conquest_result = ""
	conquest_round = 0
	conquest_treasury = {}
	conquest_last_round_log = []
	conquest_last_fought = ""
	conquest_truce = {}
	conquest_last_event = {}
	conquest_strength = 0
	conquest_fortify = {}
	conquest_industry = 0
	conquest_training = 0
	conquest_prep = {}
	conquest_armies = []
	conquest_army_seq = {}
	conquest_start_year = CONQ_START_YEAR_DEFAULT
	conquest_techs = []
	conquest_research = 0
	conquest_academy = 0
	conquest_focus = ""

func in_conquest() -> bool:
	return conquest_id != ""

# --- Powers (great powers on the strategic map) ---

func _load_powers() -> Array:
	var data := DataLoader.get_conquest(conquest_id)
	var powers: Array = data.get("powers", [])
	if not powers.is_empty():
		return powers.duplicate(true)
	# Back-compat: synthesize powers from the distinct owner values (legacy N-side).
	var seen := {}
	var out: Array = []
	for t in data.get("territories", []):
		var o := String(t.get("owner", ""))
		if o == "" or o == NEUTRAL or seen.has(o):
			continue
		seen[o] = true
		out.append({"id": o, "name": o, "color": "#888888",
			"controller": ("player" if o == "player" else "ai")})
	return out

func _find_player_power() -> String:
	for p in conquest_powers:
		if String(p.get("controller", "")) == "player":
			return String(p.get("id", ""))
	return String(conquest_powers[0].get("id", "")) if not conquest_powers.is_empty() else ""

func conquest_power(pid: String) -> Dictionary:
	for p in conquest_powers:
		if String(p.get("id", "")) == pid:
			return p
	return {}

func power_controller(pid: String) -> String:
	return String(conquest_power(pid).get("controller", ""))

# A power's historical starting war-chest (data-driven; defaults to the flat
# start). Lets each power open with resources scaled to its real fiscal strength.
func _power_start_treasury(pid: String) -> int:
	return int(conquest_power(pid).get("start_treasury", CONQ_START_STRENGTH))

func _all_powers() -> Array:
	var out: Array = []
	for p in conquest_powers:
		out.append(String(p.get("id", "")))
	return out

func _is_eliminated(pid: String) -> bool:
	return bool(conquest_eliminated.get(pid, false))

func _ai_powers_in_order() -> Array:
	var out: Array = []
	for pid in _all_powers():
		if pid != player_power_id and not _is_eliminated(pid):
			out.append(pid)
	return out

func _surviving_powers() -> Array:
	var out: Array = []
	for pid in _all_powers():
		if not _is_eliminated(pid):
			out.append(pid)
	return out

func _is_city(t: Dictionary) -> bool:
	return String(t.get("type", "city")) == "city"

func _city_count(pid: String) -> int:
	var n := 0
	for t in conquest_territories():
		if String(conquest_owner.get(String(t.get("id", "")), "")) == pid and _is_city(t):
			n += 1
	return n

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

# --- Supply network (per power) ---
# A power's supply sources are its own CITIES (plus any territory flagged
# "supply": true). A territory is supplied for its owner if a chain of that
# power's territories connects it back to a source; a territory cut off (e.g. by
# an enemy severing the chain) earns no income and can't stage offensives.

# --- Battlefield armies (CRUD + queries; positioned units on the map) ---
func army_by_id(id: String) -> Dictionary:
	for a in conquest_armies:
		if String(a.get("id", "")) == id:
			return a
	return {}

func armies_at(tid: String) -> Array:
	var out: Array = []
	for a in conquest_armies:
		if String(a.get("location", "")) == tid:
			out.append(a)
	return out

func armies_of(pid: String) -> Array:
	var out: Array = []
	for a in conquest_armies:
		if String(a.get("owner", "")) == pid:
			out.append(a)
	return out

func _create_army(owner: String, location: String, strength: int, roster: Array = []) -> Dictionary:
	var seq := int(conquest_army_seq.get(owner, 0))
	conquest_army_seq[owner] = seq + 1
	var army := {
		"id": "%s#%d" % [owner, seq],
		"owner": owner,
		"location": location,
		"strength": clampi(strength, 1, CONQ_ARMY_STR_MAX),
		"moved": false,
		"roster": roster,
	}
	conquest_armies.append(army)
	return army

func _destroy_army(id: String) -> void:
	for i in range(conquest_armies.size()):
		if String(conquest_armies[i].get("id", "")) == id:
			conquest_armies.remove_at(i)
			return

# Seed armies: from powers[].start_armies if present, else one per power on its
# lowest-id owned city. Deterministic (data / id order).
func _synthesize_armies() -> void:
	conquest_armies = []
	conquest_army_seq = {}
	var placed := false
	for p in conquest_powers:
		for s in p.get("start_armies", []):
			_create_army(String(p.get("id", "")), String(s.get("at", "")),
				int(s.get("strength", CONQ_ARMY_START_STR)))
			placed = true
	if placed:
		return
	# Garrison every starting city: a power that opens with N cities but only one
	# army would lose its other cities (garrison-only) on turn one — an instant
	# collapse. One defending army per city makes the opening board stable, so
	# conquest has to be earned rather than handed over undefended.
	for pid in _all_powers():
		if _is_eliminated(pid):
			continue
		for t in conquest_territories():
			var tid := String(t.get("id", ""))
			if String(conquest_owner.get(tid, "")) == pid and _is_city(t):
				_create_army(pid, tid, CONQ_ARMY_START_STR)

# --- Army combat + movement (integer, deterministic, ties favour defender) ---
# The successor of _est_strength/_auto_resolve, keyed to a positioned army. Local
# strength philosophy unchanged: army strength + own supplied territories massed
# around the front; the defender adds garrison/fortify/terrain + a home edge.
func _army_attack_value(army: Dictionary, tid: String) -> int:
	return int(army.get("strength", 1)) * AR_W_ARMY \
		+ _adjacent_owned_supplied(String(army.get("owner", "")), tid) * AR_W_ADJ

func _defense_value(tid: String) -> int:
	var owner := String(conquest_owner.get(tid, ""))
	var occ := armies_at(tid)
	var base := 0
	if not occ.is_empty():
		base = int(occ[0].get("strength", 1)) * AR_W_ARMY + _adjacent_owned_supplied(owner, tid) * AR_W_ADJ
	else:
		base = CONQ_GARRISON_CITY if _is_city(conquest_territory(tid)) else CONQ_GARRISON_RESOURCE
	return base + conquest_fortify_level(tid) * AR_W_FORT \
		+ int(conquest_territory(tid).get("defense", 0)) + AR_W_DEFENDER

# Auto-resolve an army's attack on a tile: on a win the defender army (if any) is
# destroyed, ownership flips, and the attacker advances onto the tile.
func _resolve_army_attack(army: Dictionary, tid: String) -> bool:
	if _army_attack_value(army, tid) > _defense_value(tid):
		for d in armies_at(tid):
			_destroy_army(String(d.get("id", "")))
		conquest_owner[tid] = String(army.get("owner", ""))
		army["location"] = tid   # advance into the captured tile
		return true
	return false   # repulsed — attacker holds its ground and survives

# --- Army movement (into an adjacent OWN, empty territory; once per round) ---
func can_move_army(army_id: String, tid: String) -> bool:
	var a := army_by_id(army_id)
	if a.is_empty() or bool(a.get("moved", false)):
		return false
	if not (tid in _conquest_neighbors(String(a.get("location", "")))):
		return false
	if String(conquest_owner.get(tid, "")) != String(a.get("owner", "")):
		return false
	return armies_at(tid).is_empty()   # no stacking

func move_army(army_id: String, tid: String) -> bool:
	if not can_move_army(army_id, tid):
		return false
	var a := army_by_id(army_id)
	a["location"] = tid
	a["moved"] = true
	save_conquest()
	return true

func conquest_supply_sources_for(pid: String) -> Array:
	var out: Array = []
	for t in conquest_territories():
		var tid := String(t.get("id", ""))
		if String(conquest_owner.get(tid, "")) != pid:
			continue
		if _is_city(t) or bool(t.get("supply", false)):
			out.append(tid)
	return out

# Dictionary[tid -> true] of pid's territories tracing supply back to a source.
func conquest_supplied_for(pid: String) -> Dictionary:
	var supplied := {}
	var stack: Array = []
	for tid in conquest_supply_sources_for(pid):
		if not supplied.has(tid):
			supplied[tid] = true
			stack.append(tid)
	while not stack.is_empty():
		var cur: String = stack.pop_back()
		for nb in _conquest_neighbors(cur):
			if String(conquest_owner.get(nb, "")) == pid and not supplied.has(nb):
				supplied[nb] = true
				stack.append(nb)
	return supplied

# Player-side aliases (keep the old names for UI/tests).
func conquest_supply_sources() -> Array:
	return conquest_supply_sources_for(player_power_id)

func conquest_supplied() -> Dictionary:
	return conquest_supplied_for(player_power_id)

func territory_supplied(tid: String) -> bool:
	var owner := String(conquest_owner.get(tid, ""))
	if owner == "" or owner == NEUTRAL:
		return false
	return conquest_supplied_for(owner).has(tid)

# UI helper: can the player attack this tile right now — i.e. does any player
# army stand adjacent and able (no defence pending, not at truce). Army-based.
func territory_attackable(tid: String) -> bool:
	if not conquest_defense_queue.is_empty():
		return false
	return not _player_army_that_can_attack(tid).is_empty()

# Count of pid's supplied territories adjacent to a front tile (local mass),
# CAPPED so a sprawling empire can't turn every border into an overwhelming
# multiplier — the cap is the key anti-snowball lever (a supported front is a
# bonus, not an ever-growing one).
func _adjacent_owned_supplied(pid: String, tid: String) -> int:
	var sup := conquest_supplied_for(pid)
	var n := 0
	for nb in _conquest_neighbors(tid):
		if String(conquest_owner.get(nb, "")) == pid and sup.has(nb):
			n += 1
	return mini(n, CONQ_ADJ_CAP)

# --- AI army turn ---

func _key_gt(a: Array, b: Array) -> bool:
	# Compare [margin, is_city, tid]: higher margin, then city, then LOWER tid (stable order).
	if int(a[0]) != int(b[0]):
		return int(a[0]) > int(b[0])
	if int(a[1]) != int(b[1]):
		return int(a[1]) > int(b[1])
	return String(a[2]) < String(b[2])

# Best adjacent enemy tile this army can take (winnable-enough), or "".
func _ai_army_target(army: Dictionary) -> String:
	var pid := String(army.get("owner", ""))
	var loc := String(army.get("location", ""))
	if not conquest_supplied_for(pid).has(loc):
		return ""   # can't stage an offensive from a cut-off tile
	var best := ""
	var best_key: Array = []
	for nb in _conquest_neighbors(loc):
		var owner := String(conquest_owner.get(nb, ""))
		if owner == pid or owner == "":
			continue   # own or off-map; NEUTRAL is a valid target
		if String(conquest_territory(nb).get("scenario", "")) == "":
			continue
		if owner == player_power_id and at_truce(pid):
			continue
		var margin := _army_attack_value(army, nb) - _defense_value(nb)
		if margin < _conq_ai_margin_min():
			continue
		var key: Array = [margin, (1 if _is_city(conquest_territory(nb)) else 0), nb]
		if best == "" or _key_gt(key, best_key):
			best_key = key
			best = nb
	return best

# One BFS step over OWN territory toward the nearest tile bordering an attackable
# enemy (single-step greedy; deterministic; "" if already at a front or none).
func _ai_march_step(army: Dictionary) -> String:
	var pid := String(army.get("owner", ""))
	var start := String(army.get("location", ""))
	var q: Array = [start]
	var prev := {start: ""}
	var goal := ""
	while not q.is_empty() and goal == "":
		var cur: String = q.pop_front()
		for nb in _conquest_neighbors(cur):
			var o := String(conquest_owner.get(nb, ""))
			if o != pid and o != "" and String(conquest_territory(nb).get("scenario", "")) != "":
				goal = cur
				break
		if goal != "":
			break
		for nb in _conquest_neighbors(cur):
			if String(conquest_owner.get(nb, "")) == pid and not prev.has(nb):
				prev[nb] = cur
				q.append(nb)
	if goal == "" or goal == start:
		return ""
	var step := goal
	while String(prev.get(step, "")) != start and String(prev.get(step, "")) != "":
		step = String(prev[step])
	if step in _conquest_neighbors(start) and armies_at(step).is_empty() \
		and String(conquest_owner.get(step, "")) == pid:
		return step
	return ""

# --- Difficulty ladder for the rival powers' strategic AI ---
func _conq_ai_army_max() -> int:
	match conquest_difficulty:
		"easy": return 2
		"hard": return 6
	return CONQ_AI_ARMY_MAX

func _conq_ai_margin_min() -> int:
	# Minimum estimated margin before an AI will launch an attack (higher = timid).
	return 3 if conquest_difficulty == "easy" else 1

func _conq_ai_income_bonus() -> int:
	return 1 if conquest_difficulty == "hard" else 0

func _conq_ai_fortifies() -> bool:
	return conquest_difficulty != "easy"

# Set the grand game's difficulty (chosen at its start; persisted).
func set_conquest_difficulty(d: String) -> void:
	if in_conquest():
		conquest_difficulty = d
		save_conquest()

# --- Diplomacy: player-brokered truces (mutual non-aggression for N rounds) ---
func at_truce(pid: String) -> bool:
	return int(conquest_truce.get(pid, 0)) > 0

func truce_rounds(pid: String) -> int:
	return int(conquest_truce.get(pid, 0))

func can_offer_truce(pid: String) -> bool:
	return in_conquest() and pid != player_power_id and pid != NEUTRAL and pid != "" \
		and not _is_eliminated(pid) and not at_truce(pid) \
		and conquest_defense_queue.is_empty() and conquest_strength >= CONQ_TRUCE_COST

func offer_truce(pid: String) -> bool:
	if not can_offer_truce(pid):
		return false
	conquest_strength -= CONQ_TRUCE_COST
	conquest_truce[pid] = CONQ_TRUCE_ROUNDS
	save_conquest()
	return true

# AI army economy: raise a new army at a supplied army-less city (under the
# difficulty cap), else reinforce an under-strength army on a supplied city.
func _conq_ai_army_cap() -> int:
	match conquest_difficulty:
		"easy": return 2
		"hard": return 4
	return 3

func _ai_economy(pid: String) -> void:
	var treas := int(conquest_treasury.get(pid, 0))
	if armies_of(pid).size() < _conq_ai_army_cap() and treas >= CONQ_RAISE_COST:
		var sup := conquest_supplied_for(pid)
		for t in conquest_territories():
			var tid := String(t.get("id", ""))
			if String(conquest_owner.get(tid, "")) == pid and _is_city(t) and sup.has(tid) and armies_at(tid).is_empty():
				conquest_treasury[pid] = treas - CONQ_RAISE_COST
				_create_army(pid, tid, CONQ_ARMY_START_STR)
				return
	if treas >= CONQ_REINFORCE_COST:
		var sup2 := conquest_supplied_for(pid)
		for a in armies_of(pid):
			if int(a.get("strength", 1)) < CONQ_ARMY_STR_MAX and sup2.has(String(a.get("location", ""))):
				conquest_treasury[pid] = treas - CONQ_REINFORCE_COST
				a["strength"] = int(a.get("strength", 1)) + 1
				return

func _ai_take_turn(pid: String) -> void:
	_ai_economy(pid)
	for army in armies_of(pid):
		if bool(army.get("moved", false)):
			continue
		var tgt := _ai_army_target(army)
		if tgt != "":
			army["moved"] = true
			var defender := String(conquest_owner.get(tgt, ""))
			if defender == player_power_id and not armies_at(tgt).is_empty():
				# The player has an army there — they must play the defence.
				conquest_defense_queue.append({"attacker": pid, "territory": tgt, "attacker_army": String(army.get("id", ""))})
				conquest_last_round_log.append({"power": pid, "kind": "attack_player", "territory": tgt})
			else:
				var won := _resolve_army_attack(army, tgt)   # AI-vs-AI or vs an undefended tile
				conquest_last_round_log.append({"power": pid, "kind": "auto", "territory": tgt, "won": won})
				if won:
					_check_eliminations(pid)
		else:
			var step := _ai_march_step(army)
			if step != "":
				army["location"] = step
				army["moved"] = true

# Advance one strategic round: every surviving AI power expands (AI-vs-AI auto-
# resolved, AI-vs-player queued as a defence), then all powers collect income.
# Refuses while a defence is pending or a battle is mid-flight (resolve those
# first). Returns false if it could not advance.
func advance_conquest_round() -> bool:
	if not in_conquest() or conquest_over():
		return false
	if not conquest_defense_queue.is_empty() or not conquest_battle.is_empty():
		return false
	conquest_last_round_log = []
	for a in conquest_armies:
		a["moved"] = false          # every army may act again this round
	for pid in _ai_powers_in_order():
		_ai_take_turn(pid)
	for pid in _all_powers():
		if not _is_eliminated(pid):
			_grant_income(pid)
	# The player earns research each round to advance up the tech tree.
	if not _is_eliminated(player_power_id):
		conquest_research += _conquest_research_income()
	conquest_secured = {}          # repel immunity lasts only the round it was earned
	# Truces count down and lapse.
	var truces := {}
	for pid in conquest_truce:
		var r := int(conquest_truce[pid]) - 1
		if r > 0:
			truces[pid] = r
	conquest_truce = truces
	conquest_round += 1
	_maybe_fire_event()
	_update_victory_state()
	save_conquest()
	return true

# --- Historical events (deterministic, player-only) ---
func _maybe_fire_event() -> void:
	conquest_last_event = {}
	if CONQ_EVENTS.is_empty():
		return
	if abs(hash("evt:%d" % conquest_round)) % 100 >= CONQ_EVENT_CHANCE:
		return
	var evt: Dictionary = CONQ_EVENTS[abs(hash("evtpick:%d" % conquest_round)) % CONQ_EVENTS.size()]
	_apply_event(evt)
	conquest_last_event = evt

func _apply_event(evt: Dictionary) -> void:
	match String(evt.get("kind", "")):
		"resource":
			conquest_strength = max(0, conquest_strength + int(evt.get("amount", 0)))
		"recruit":
			var ra := _player_primary_army()
			if not ra.is_empty() and ra.get("roster", []).size() < CONQ_ROSTER_MAX:
				ra["roster"].append({"type": _recruit_type(), "name": "義勇兵",
					"xp": conquest_training * CONQ_TRAIN_XP, "rank": 0, "general": ""})
		"prep":
			conquest_prep[String(evt.get("prep", "recon"))] = true
		"fortify":
			_event_fortify()
		"revolt":
			_event_revolt()
		"promote":
			var pa := _player_primary_army()
			var pr: Array = pa.get("roster", []) if not pa.is_empty() else []
			var pi := _lowest_rank_idx(pr)
			if pi >= 0 and int(pr[pi].get("rank", 0)) < ROSTER_RANK_MAX:
				pr[pi]["rank"] = int(pr[pi].get("rank", 0)) + 1
		"disband":
			var da := _player_primary_army()
			var dr: Array = da.get("roster", []) if not da.is_empty() else []
			var di := _lowest_rank_idx(dr)   # lose the greenest unit — a bounded setback
			if di >= 0:
				dr.remove_at(di)

func _event_fortify() -> void:
	var sup := conquest_supplied_for(player_power_id)
	var best := ""
	var best_f := CONQ_FORTIFY_MAX
	for t in conquest_territories():
		var tid := String(t.get("id", ""))
		if String(conquest_owner.get(tid, "")) != player_power_id or not _is_city(t) or not sup.has(tid):
			continue
		var f := conquest_fortify_level(tid)
		if f < best_f:
			best_f = f
			best = tid
	if best != "":
		conquest_fortify[best] = best_f + 1

func _event_revolt() -> void:
	# A player RESOURCE territory slips to neutral — never a city, so an event can
	# never take your last city and cause defeat.
	for t in conquest_territories():
		var tid := String(t.get("id", ""))
		if String(conquest_owner.get(tid, "")) == player_power_id and not _is_city(t):
			conquest_owner[tid] = NEUTRAL
			return

func _grant_income(pid: String) -> void:
	var inc := conquest_income_for(pid)
	if pid == player_power_id:
		conquest_strength += inc
	else:
		conquest_treasury[pid] = int(conquest_treasury.get(pid, 0)) + inc + _conq_ai_income_bonus()

# --- Battle setup / resolution (the tactical layer stays two-sided) ---

# Can this army attack this tile? adjacent enemy (or neutral) battle-bearing tile,
# staged from a supplied own tile, not at truce, and the army hasn't acted.
func can_army_attack(army_id: String, tid: String) -> bool:
	var a := army_by_id(army_id)
	if a.is_empty() or bool(a.get("moved", false)):
		return false
	var owner := String(a.get("owner", ""))
	var target_owner := String(conquest_owner.get(tid, ""))
	if target_owner == owner or target_owner == "":
		return false
	if owner == player_power_id and at_truce(target_owner):
		return false
	if String(conquest_territory(tid).get("scenario", "")) == "":
		return false
	if not (tid in _conquest_neighbors(String(a.get("location", "")))):
		return false
	return conquest_supplied_for(owner).has(String(a.get("location", "")))

func _player_army_that_can_attack(tid: String) -> Dictionary:
	for a in armies_of(player_power_id):
		if can_army_attack(String(a.get("id", "")), tid):
			return a
	return {}

func _battle_fielding_army() -> Dictionary:
	return army_by_id(String(conquest_battle.get("army", "")))

func _active_battle_roster() -> Array:
	var fa := _battle_fielding_army()
	return fa.get("roster", []) if not fa.is_empty() else []

# Any surviving player army on a supplied city — receives recruit/reinforce and events.
func _player_primary_army() -> Dictionary:
	var sup := conquest_supplied_for(player_power_id)
	var best := {}
	for a in armies_of(player_power_id):
		if sup.has(String(a.get("location", ""))) and _is_city(conquest_territory(String(a.get("location", "")))):
			if best.is_empty() or String(a.get("id", "")) < String(best.get("id", "")):
				best = a
	return best

# Begin a player attack from `army_id` (or an auto-selected adjacent army) onto tid.
func begin_conquest_attack(tid: String, army_id: String = "") -> bool:
	if not conquest_defense_queue.is_empty():
		return false
	var a := army_by_id(army_id) if army_id != "" else _player_army_that_can_attack(tid)
	if a.is_empty() or String(a.get("owner", "")) != player_power_id:
		return false
	if not can_army_attack(String(a.get("id", "")), tid):
		return false
	var enemy := armies_at(tid)
	conquest_battle = {"territory": tid, "defense": false,
		"attacker": player_power_id, "defender": String(conquest_owner.get(tid, "")),
		"army": String(a.get("id", "")),
		"enemy_army": (String(enemy[0].get("id", "")) if not enemy.is_empty() else "")}
	current_scenario_id = String(conquest_territory(tid).get("scenario", ""))
	return true

# Peek the next VALID queued defence (player still owns the tile AND has an army
# there). Stale entries auto-resolve the recorded attacker army vs the tile.
func _peek_defense() -> Dictionary:
	while not conquest_defense_queue.is_empty():
		var e: Dictionary = conquest_defense_queue[0]
		var etid := String(e.get("territory", ""))
		if String(conquest_owner.get(etid, "")) == player_power_id and not armies_at(etid).is_empty():
			return e
		var stale: Dictionary = conquest_defense_queue.pop_front()
		var atk := army_by_id(String(stale.get("attacker_army", "")))
		if not atk.is_empty():
			_resolve_army_attack(atk, etid)
			_check_eliminations(String(stale.get("attacker", "")))
	return {}

func begin_conquest_defense() -> bool:
	var e := _peek_defense()
	if e.is_empty():
		return false
	var tid := String(e.get("territory", ""))
	var def_army := armies_at(tid)
	conquest_battle = {"territory": tid, "defense": true,
		"attacker": String(e.get("attacker", "")), "defender": player_power_id,
		"army": (String(def_army[0].get("id", "")) if not def_army.is_empty() else ""),
		"enemy_army": String(e.get("attacker_army", ""))}
	current_scenario_id = String(conquest_territory(tid).get("scenario", ""))
	return true

func has_enemy_counter() -> bool:
	return not _peek_defense().is_empty()

func conquest_pending_defenses() -> Array:
	return conquest_defense_queue

func cancel_conquest_battle() -> void:
	conquest_battle = {}

# Apply a finished battle to the strategic map (army-aware). Round income/AI
# expansion happen in advance_conquest_round, NOT here.
func resolve_conquest_battle(player_won: bool) -> void:
	var tid := String(conquest_battle.get("territory", ""))
	var defense: bool = bool(conquest_battle.get("defense", false))
	var attacker := String(conquest_battle.get("attacker", ""))
	var army_id := String(conquest_battle.get("army", ""))
	var enemy_army_id := String(conquest_battle.get("enemy_army", ""))
	conquest_battle = {}
	conquest_prep = {}
	if tid == "":
		return
	conquest_last_fought = tid
	var my_army := army_by_id(army_id)
	var conqueror := ""
	if defense:
		if not conquest_defense_queue.is_empty():
			conquest_defense_queue.pop_front()
		if player_won:
			conquest_secured[tid] = true
			if enemy_army_id != "":
				_destroy_army(enemy_army_id)          # repelled attacker destroyed
		else:
			conquest_owner[tid] = attacker
			conqueror = attacker
			if not my_army.is_empty():
				_destroy_army(army_id)                # defending army destroyed
			var atk := army_by_id(enemy_army_id)
			if not atk.is_empty():
				atk["location"] = tid                 # attacker advances in
	else:
		if not my_army.is_empty():
			my_army["moved"] = true
		if player_won:
			conquest_owner[tid] = player_power_id
			conqueror = player_power_id
			if enemy_army_id != "":
				_destroy_army(enemy_army_id)
			if not my_army.is_empty():
				my_army["location"] = tid             # advance into the captured tile
		# attack lost: the army holds its ground (retreat) and survives
	_check_eliminations(conqueror)
	_update_victory_state()
	save_conquest()

# --- Elimination & victory ---

func _check_eliminations(conqueror: String) -> void:
	for pid in _all_powers():
		if _is_eliminated(pid):
			continue
		if _city_count(pid) == 0:
			_eliminate(pid, conqueror)

func _eliminate(pid: String, conqueror: String) -> void:
	conquest_eliminated[pid] = true
	var heir := conqueror
	if heir == "" or heir == pid or _is_eliminated(heir):
		heir = NEUTRAL
	for t in conquest_territories():
		var tid := String(t.get("id", ""))
		if String(conquest_owner.get(tid, "")) == pid:
			conquest_owner[tid] = heir
	var kept: Array = []          # an eliminated power's armies are disbanded
	for a in conquest_armies:
		if String(a.get("owner", "")) != pid:
			kept.append(a)
	conquest_armies = kept

func _update_victory_state() -> void:
	if conquest_result != "":
		return
	if _is_eliminated(player_power_id) or _city_count(player_power_id) == 0:
		conquest_result = "lost"
	elif _surviving_powers().size() <= 1:
		conquest_result = "won"

func conquest_won() -> bool:
	return in_conquest() and conquest_result == "won"

func conquest_lost() -> bool:
	return in_conquest() and conquest_result == "lost"

func conquest_over() -> bool:
	return conquest_result != ""

func conquest_counts() -> Dictionary:
	var player_terr := 0
	var player_cities := 0
	var total := 0
	for t in conquest_territories():
		total += 1
		if String(conquest_owner.get(String(t.get("id", "")), "")) == player_power_id:
			player_terr += 1
			if _is_city(t):
				player_cities += 1
	return {"player": player_terr, "player_cities": player_cities, "total": total,
		"powers_alive": _surviving_powers().size()}

# Per-power {territories, cities, eliminated} for the UI standings strip.
func conquest_power_counts() -> Dictionary:
	var out := {}
	for pid in _all_powers():
		out[pid] = {"territories": 0, "cities": 0, "eliminated": _is_eliminated(pid)}
	for t in conquest_territories():
		var o := String(conquest_owner.get(String(t.get("id", "")), ""))
		if out.has(o):
			out[o]["territories"] += 1
			if _is_city(t):
				out[o]["cities"] += 1
	return out

# Strength earned per round by a power: base per supplied city + supplied
# resource yields; the player also adds industry. Cut-off territories yield none.
func conquest_income_for(pid: String) -> int:
	var total := 0
	for tid in conquest_supplied_for(pid):
		var t := conquest_territory(tid)
		if _is_city(t):
			total += CONQ_CITY_BASE + int(t.get("yield", 0))
		else:
			total += int(t.get("yield", RESOURCE_DEFAULT_YIELD))
	if pid == player_power_id:
		total += conquest_industry
	return total

func conquest_income() -> int:
	return conquest_income_for(player_power_id)

# 整軍: reinforce the player's primary army's strength (was a global army level).
func can_muster() -> bool:
	var a := _player_primary_army()
	return in_conquest() and not a.is_empty() and int(a.get("strength", 1)) < CONQ_ARMY_STR_MAX \
		and conquest_strength >= CONQ_MUSTER_COST

func muster() -> bool:
	if not can_muster():
		return false
	conquest_strength -= CONQ_MUSTER_COST
	var a := _player_primary_army()
	a["strength"] = int(a.get("strength", 1)) + 1
	save_conquest()
	return true

func can_fortify(tid: String) -> bool:
	if not in_conquest() or String(conquest_owner.get(tid, "")) != player_power_id:
		return false
	if String(conquest_territory(tid).get("scenario", "")) == "":
		return false  # the home base has no battle to fortify
	if not territory_supplied(tid):
		return false  # can't ship fortification materials to a cut-off territory
	return int(conquest_fortify.get(tid, 0)) < CONQ_FORTIFY_MAX and conquest_strength >= CONQ_FORTIFY_COST

func fortify(tid: String) -> bool:
	if not can_fortify(tid):
		return false
	conquest_strength -= CONQ_FORTIFY_COST
	conquest_fortify[tid] = int(conquest_fortify.get(tid, 0)) + 1
	save_conquest()
	return true

func conquest_fortify_level(tid: String) -> int:
	return int(conquest_fortify.get(tid, 0))

# --- Development tracks (global, permanent) ---

func _develop_state(track: String) -> Array:
	# [current level, cost, max] for a development track, or [] if unknown.
	match track:
		"industry": return [conquest_industry, CONQ_INDUSTRY_COST, CONQ_INDUSTRY_MAX]
		"training": return [conquest_training, CONQ_TRAINING_COST, CONQ_TRAINING_MAX]
		"academy": return [conquest_academy, CONQ_ACADEMY_COST, CONQ_ACADEMY_MAX]
	return []

func can_develop(track: String) -> bool:
	var s := _develop_state(track)
	if s.is_empty() or not in_conquest():
		return false
	return int(s[0]) < int(s[2]) and conquest_strength >= int(s[1])

func develop(track: String) -> bool:
	if not can_develop(track):
		return false
	var s := _develop_state(track)
	conquest_strength -= int(s[1])
	match track:
		"industry": conquest_industry += 1
		"training": conquest_training += 1
		"academy": conquest_academy += 1
	save_conquest()
	return true

func develop_level(track: String) -> int:
	var s := _develop_state(track)
	return int(s[0]) if not s.is_empty() else 0

# --- Pre-battle preparations (one-shot, applied to the next battle) ---

func can_prepare(kind: String) -> bool:
	if not in_conquest() or not CONQ_PREP_COST.has(kind):
		return false
	if bool(conquest_prep.get(kind, false)):
		return false   # already bought for the pending battle
	return conquest_strength >= int(CONQ_PREP_COST[kind])

func prepare(kind: String) -> bool:
	if not can_prepare(kind):
		return false
	conquest_strength -= int(CONQ_PREP_COST[kind])
	conquest_prep[kind] = true
	save_conquest()
	return true

func prep_active(kind: String) -> bool:
	return bool(conquest_prep.get(kind, false))

# --- City actions: recruit fresh troops / reinforce, at a supplied city ---

func conquest_has_supplied_city() -> bool:
	var sup := conquest_supplied_for(player_power_id)
	for t in conquest_territories():
		var tid := String(t.get("id", ""))
		if _is_city(t) and String(conquest_owner.get(tid, "")) == player_power_id and sup.has(tid):
			return true
	return false

func _recruit_type() -> String:
	return String(DataLoader.get_conquest(conquest_id).get("recruit_unit", "musketeers"))

func can_recruit() -> bool:
	var a := _player_primary_army()
	return in_conquest() and not a.is_empty() \
		and a.get("roster", []).size() < CONQ_ROSTER_MAX and conquest_strength >= CONQ_RECRUIT_COST

func recruit() -> bool:
	if not can_recruit():
		return false
	conquest_strength -= CONQ_RECRUIT_COST
	_player_primary_army()["roster"].append({"type": _recruit_type(), "name": "新兵",
		"xp": conquest_training * CONQ_TRAIN_XP, "rank": 0, "general": ""})
	save_conquest()
	return true

func _lowest_rank_idx(roster: Array) -> int:
	var idx := -1
	var best := 9999
	for i in range(roster.size()):
		var r := int(roster[i].get("rank", 0))
		if r < best:
			best = r
			idx = i
	return idx

func can_heal() -> bool:
	var a := _player_primary_army()
	if not in_conquest() or a.is_empty() or conquest_strength < CONQ_HEAL_COST:
		return false
	var r: Array = a.get("roster", [])
	var i := _lowest_rank_idx(r)
	return i >= 0 and int(r[i].get("rank", 0)) < ROSTER_RANK_MAX

func heal() -> bool:
	if not can_heal():
		return false
	conquest_strength -= CONQ_HEAL_COST
	var r: Array = _player_primary_army().get("roster", [])
	var i := _lowest_rank_idx(r)
	r[i]["rank"] = int(r[i].get("rank", 0)) + 1
	save_conquest()
	return true

# --- Conquest persistence (a grand game spans many sessions) ---
# The whole strategic state is snapshotted to user:// after every state change.
# A finished game (won/lost) deletes its save so it isn't offered as resumable.

func has_conquest_save() -> bool:
	return FileAccess.file_exists(CONQUEST_SAVE_PATH)

func delete_conquest_save() -> void:
	var d := DirAccess.open("user://")
	if d != null and d.file_exists(CONQUEST_SAVE_FILE):
		d.remove(CONQUEST_SAVE_FILE)

func save_conquest() -> void:
	if not in_conquest():
		return
	if conquest_over():
		delete_conquest_save()   # a decided game is not resumable
		return
	var data := {
		"conquest_id": conquest_id,
		"player_power_id": player_power_id,
		"owner": conquest_owner,
		"secured": conquest_secured,
		"defense_queue": conquest_defense_queue,
		"eliminated": conquest_eliminated,
		"result": conquest_result,
		"round": conquest_round,
		"treasury": conquest_treasury,
		"last_round_log": conquest_last_round_log,
		"last_fought": conquest_last_fought,
		"difficulty": conquest_difficulty,
		"truce": conquest_truce,
		"last_event": conquest_last_event,
		"armies": conquest_armies,
		"army_seq": conquest_army_seq,
		"strength": conquest_strength,
		"fortify": conquest_fortify,
		"industry": conquest_industry,
		"training": conquest_training,
		"prep": conquest_prep,
		"start_year": conquest_start_year,
		"techs": conquest_techs,
		"research": conquest_research,
		"academy": conquest_academy,
		"focus": conquest_focus,
	}
	var f := FileAccess.open(CONQUEST_SAVE_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(data))
	f.close()

func load_conquest() -> bool:
	if not FileAccess.file_exists(CONQUEST_SAVE_PATH):
		return false
	var f := FileAccess.open(CONQUEST_SAVE_PATH, FileAccess.READ)
	if f == null:
		return false
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return false
	var qid := String(parsed.get("conquest_id", ""))
	if qid == "" or DataLoader.get_conquest(qid).is_empty():
		delete_conquest_save()
		return false
	conquest_id = qid
	conquest_powers = _load_powers()
	player_power_id = String(parsed.get("player_power_id", _find_player_power()))
	conquest_owner = parsed.get("owner", {})
	conquest_secured = parsed.get("secured", {})
	conquest_defense_queue = parsed.get("defense_queue", [])
	conquest_eliminated = parsed.get("eliminated", {})
	conquest_result = String(parsed.get("result", ""))
	conquest_round = int(parsed.get("round", 0))
	conquest_treasury = parsed.get("treasury", {})
	conquest_last_round_log = parsed.get("last_round_log", [])
	conquest_last_fought = String(parsed.get("last_fought", ""))
	conquest_difficulty = String(parsed.get("difficulty", "normal"))
	conquest_truce = parsed.get("truce", {})
	conquest_last_event = parsed.get("last_event", {})
	conquest_strength = int(parsed.get("strength", 0))
	conquest_fortify = parsed.get("fortify", {})
	conquest_industry = int(parsed.get("industry", 0))
	conquest_training = int(parsed.get("training", 0))
	conquest_prep = parsed.get("prep", {})
	conquest_armies = parsed.get("armies", [])
	conquest_army_seq = parsed.get("army_seq", {})
	if conquest_armies.is_empty():
		_synthesize_armies()   # migrate a pre-armies save
	conquest_start_year = int(parsed.get("start_year", CONQ_START_YEAR_DEFAULT))
	conquest_research = int(parsed.get("research", 0))
	conquest_techs = parsed.get("techs", _techs_up_to_year(conquest_start_year))  # pre-tech save -> era baseline
	conquest_academy = int(parsed.get("academy", 0))
	conquest_focus = String(parsed.get("focus", ""))
	conquest_battle = {}
	player_faction_override = ""
	return true
