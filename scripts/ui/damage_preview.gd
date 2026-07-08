class_name DamagePreview
extends RefCounted

# Stateless prediction: given an attacker + defender + context, returns what
# WOULD happen if the attack resolved — mirroring CombatResolver.resolve but
# never mutating anything. battle.gd wires it to hover so the player sees the
# expected damage / counter / kill before committing. Shares CombatRules and
# CombatResolver with real combat, so the preview can never drift from reality.

const CombatResolver := preload("res://scripts/combat/combat_resolver.gd")
const CombatRules := preload("res://scripts/combat/combat_rules.gd")
const CombatModifiers := preload("res://scripts/combat/combat_modifiers.gd")
const HexCoord := preload("res://scripts/grid/hex_coord.gd")

static func preview(
	attacker,
	defender,
	atk_def: Dictionary,
	def_def: Dictionary,
	atk_general: Dictionary,
	def_general: Dictionary,
	atk_terrain_def: Dictionary,
	def_terrain_def: Dictionary,
	visible_hexes: Dictionary,
	hex_map,
) -> Dictionary:
	var distance: int = HexCoord.distance(attacker.coord, defender.coord)
	var out := {
		"legal": false, "reason": "",
		"dmg": 0, "counter": 0,
		"defender_dies": false, "attacker_dies": false,
		"distance": distance,
	}
	if not CombatRules.can_attack_target(attacker, defender, atk_def, hex_map, visible_hexes):
		out["reason"] = _explain_illegality(attacker, defender, atk_def, distance, visible_hexes)
		return out
	var atk_mods: Dictionary = CombatModifiers.for_unit(attacker, atk_general)
	var def_mods: Dictionary = CombatModifiers.for_unit(defender, def_general)
	var result = CombatResolver.resolve(
		atk_def, def_def, attacker.hp, defender.hp,
		atk_terrain_def, def_terrain_def, distance,
		defender.dig_in_level, atk_mods, def_mods)
	out["legal"] = true
	out["dmg"] = result.damage_to_defender
	out["counter"] = result.counter_damage
	out["defender_dies"] = result.defender_dies
	out["attacker_dies"] = result.attacker_dies
	return out

# One-line summary for the HUD.
static func summary(p: Dictionary, attacker, defender) -> String:
	if not p.get("legal", false):
		return "%s → %s:%s" % [attacker.display_name, defender.display_name, p.get("reason", "無法攻擊")]
	var s := "⚔ %s → %s:預估 %d 傷" % [attacker.display_name, defender.display_name, int(p.get("dmg", 0))]
	if p.get("defender_dies", false):
		s += " · [擊殺]"
	elif int(p.get("counter", 0)) > 0:
		s += " · 反擊 %d%s" % [int(p.get("counter", 0)), " · [我方陣亡]" if p.get("attacker_dies", false) else ""]
	return s

static func _explain_illegality(attacker, defender, atk_def: Dictionary, distance: int, visible_hexes: Dictionary) -> String:
	if attacker.faction_id == defender.faction_id:
		return "同陣營"
	if not defender.is_alive():
		return "目標已陣亡"
	if distance > int(atk_def.get("range", 1)):
		return "超出射程 (%d > %d)" % [distance, int(atk_def.get("range", 1))]
	if not visible_hexes.has(defender.coord):
		return "目標不在視野"
	return "視線被阻擋"
