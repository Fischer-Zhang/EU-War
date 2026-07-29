extends SceneTree

# Non-headless screenshot harness: boot the conquest map on grand_europe, pick a
# player army so move/attack highlights show, render a few frames, save a PNG.

func _init() -> void:
	_run.call_deferred()

func _run() -> void:
	get_root().size = Vector2i(1280, 720)
	var gs = get_root().get_node("GameState")
	gs.start_conquest("grand_europe")
	var map = load("res://scenes/conquest_map.tscn").instantiate()
	get_root().add_child(map)
	await process_frame
	await process_frame
	# Pick the player's first army so its order-highlights render.
	var armies = gs.armies_of(gs.player_power_id)
	if armies.size() > 0:
		map._on_territory_clicked(String(armies[0].get("location", "")))
	for i in range(8):
		await process_frame
	var img := get_root().get_texture().get_image()
	img.save_png("scratchpad/conquest_shot.png")
	print("saved scratchpad/conquest_shot.png ", img.get_size())
	quit(0)
