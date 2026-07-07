extends SceneTree

# CombatResolver tests — defs passed directly, no DataLoader needed.

const CombatResolver := preload("res://scripts/combat/combat_resolver.gd")

func _init() -> void:
	var pass_count := 0
	var fail_count := 0

	var pikemen := {"id": "pikemen", "hp": 12, "attack": 4, "defense": 3, "range": 1, "vs_armor": 4, "armor": 1}
	var knight := {"id": "heavy_cavalry", "hp": 16, "attack": 8, "defense": 5, "range": 1, "vs_armor": 2, "armor": 5}
	var longbow := {"id": "longbowmen", "hp": 9, "attack": 5, "defense": 1, "range": 2, "vs_armor": 2, "armor": 0}
	var skirmisher := {"id": "skirmisher", "hp": 10, "attack": 4, "defense": 2, "range": 1, "vs_armor": 1, "armor": 0}
	var cannon := {"id": "field_cannon", "hp": 8, "attack": 8, "defense": 1, "range": 4, "vs_armor": 3, "armor": 0, "indirect": true}
	var plain := {"defense": 0}
	var hills := {"defense": 2}

	# 1) Pike vs armored knight: pikes get the vs_armor bonus. 4 + 4 - 5 = 3.
	var r := CombatResolver.resolve(pikemen, knight, 12, 16, plain, plain, 1)
	if r.damage_to_defender == 3 and not r.defender_dies:
		pass_count += 1
	else:
		fail_count += 1; printerr("FAIL: pike vs knight dmg=%d" % r.damage_to_defender)

	# 2) Cover reduces damage: longbow vs unarmored skirmisher on hills: 5-2-2 = 1.
	var r2 := CombatResolver.resolve(longbow, skirmisher, 9, 10, plain, hills, 2)
	if r2.damage_to_defender == 1:
		pass_count += 1
	else:
		fail_count += 1; printerr("FAIL: cover dmg=%d" % r2.damage_to_defender)

	# 3) A ranged attacker at distance 2 takes NO counter from a range-1 defender.
	if r2.counter_damage == 0:
		pass_count += 1
	else:
		fail_count += 1; printerr("FAIL: ranged no-counter counter=%d" % r2.counter_damage)

	# 4) Wounded attacker hits softer: pike at half HP. round(3 * 0.5) = 2.
	var r3 := CombatResolver.resolve(pikemen, knight, 6, 16, plain, plain, 1)
	if r3.damage_to_defender == 2:
		pass_count += 1
	else:
		fail_count += 1; printerr("FAIL: wounded scaling dmg=%d" % r3.damage_to_defender)

	# 5) An INDIRECT defender (cannon) never counter-attacks, even adjacent.
	var r5 := CombatResolver.resolve(knight, cannon, 16, 8, plain, plain, 1)
	if r5.counter_damage == 0:
		pass_count += 1
	else:
		fail_count += 1; printerr("FAIL: indirect defender no-counter counter=%d" % r5.counter_damage)

	# 6) Lethal hit flags defender_dies and drops the counter.
	var r6 := CombatResolver.resolve(knight, longbow, 16, 3, plain, plain, 1)
	if r6.defender_dies and r6.counter_damage == 0:
		pass_count += 1
	else:
		fail_count += 1; printerr("FAIL: lethal died=%s counter=%d" % [r6.defender_dies, r6.counter_damage])

	# 7) Field fortification (dig-in) reduces incoming damage.
	var base := CombatResolver.resolve(knight, pikemen, 16, 12, plain, plain, 1).damage_to_defender
	var dug := CombatResolver.resolve(knight, pikemen, 16, 12, plain, plain, 1, 2).damage_to_defender
	if dug < base:
		pass_count += 1
	else:
		fail_count += 1; printerr("FAIL: dig-in base=%d dug=%d" % [base, dug])

	print("test_combat_resolver: %d passed, %d failed" % [pass_count, fail_count])
	quit(1 if fail_count > 0 else 0)
