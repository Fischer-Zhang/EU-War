extends SceneTree

# The attack preview must never drift from real combat: it shares CombatResolver
# with resolution, so preview.dmg must equal what the resolver produces, and
# illegal targets must be reported as such.

const DamagePreview = preload("res://scripts/ui/damage_preview.gd")
const CombatResolver = preload("res://scripts/combat/combat_resolver.gd")

var fails := 0

func ok(cond: bool, msg: String) -> void:
	if cond:
		print("  PASS: ", msg)
	else:
		fails += 1
		printerr("  FAIL: ", msg)

class FakeUnit:
	extends RefCounted
	var coord: Vector2i
	var hp: int
	var faction_id: String
	var type_id: String
	var general_id: String = ""
	var rank: int = 0
	var dig_in_level: int = 0
	var display_name: String = "U"
	func _init(t, f, c, h): type_id = t; faction_id = f; coord = c; hp = h
	func is_alive(): return hp > 0

class StubMap:
	extends RefCounted
	func terrain_at(_c): return "plain"
	func blocks_los_at(_c): return false
	func unit_at(_c): return null

func _init() -> void:
	_run.call_deferred()

func _run() -> void:
	var dl = root.get_node("DataLoader")
	await process_frame
	var lb = dl.get_unit_def("longbowmen")     # range 2
	var maa = dl.get_unit_def("men_at_arms")
	var plain := {"defense": 0}
	var m := StubMap.new()

	var atk = FakeUnit.new("longbowmen", "blue", Vector2i(0, 0), lb.hp)
	atk.display_name = "長弓隊"
	var target = FakeUnit.new("men_at_arms", "red", Vector2i(0, 2), maa.hp)   # distance 2, in range
	target.display_name = "敵重步"
	var vis := {target.coord: true}

	var p = DamagePreview.preview(atk, target, lb, maa, {}, {}, plain, plain, vis, m)
	ok(p.legal, "in-range visible target is a legal preview")
	var real = CombatResolver.resolve(lb, maa, atk.hp, target.hp, plain, plain, 2, 0, {}, {}).damage_to_defender
	ok(p.dmg == real, "preview dmg (%d) matches the resolver (%d)" % [p.dmg, real])
	ok(p.counter == 0, "range-2 shot predicts no counter from a range-1 defender")
	ok(DamagePreview.summary(p, atk, target).find("預估") >= 0, "summary mentions the estimate")

	# Lethal prediction.
	target.hp = 1
	var pk = DamagePreview.preview(atk, target, lb, maa, {}, {}, plain, plain, vis, m)
	ok(pk.defender_dies, "predicts a kill when the hit is lethal")
	ok(DamagePreview.summary(pk, atk, target).find("擊殺") >= 0, "summary flags a kill")

	# Out of range -> illegal with a reason.
	target.hp = maa.hp
	target.coord = Vector2i(0, 4)   # distance 4 > range 2
	var po = DamagePreview.preview(atk, target, lb, maa, {}, {}, plain, plain, {target.coord: true}, m)
	ok(not po.legal, "out-of-range target is illegal")
	ok(po.reason.find("射程") >= 0, "reason explains it is out of range")

	if fails == 0:
		print("test_damage_preview: ok")
		quit(0)
	else:
		printerr("test_damage_preview: %d failures" % fails)
		quit(1)
