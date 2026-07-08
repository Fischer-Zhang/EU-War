extends Control

@onready var single_battle_button: Button = $VBox/SingleBattleButton
@onready var quit_button: Button = $VBox/QuitButton

func _ready() -> void:
	single_battle_button.pressed.connect(_on_single_battle_pressed)
	quit_button.pressed.connect(_on_quit_pressed)
	_add_campaign_button()
	_add_conquest_button()
	_add_tech_button()
	_add_help_button()
	single_battle_button.grab_focus()

func _add_help_button() -> void:
	if DataLoader.help.is_empty():
		return
	var vbox := single_battle_button.get_parent()
	var btn := Button.new()
	btn.text = "如何遊玩"
	btn.custom_minimum_size = single_battle_button.custom_minimum_size
	btn.add_theme_font_size_override("font_size",
		single_battle_button.get_theme_font_size("font_size"))
	btn.pressed.connect(func(): get_tree().change_scene_to_file("res://scenes/help.tscn"))
	vbox.add_child(btn)
	vbox.move_child(btn, quit_button.get_index())

# Built at runtime and inserted just after the single-battle button so the menu
# scene doesn't need editing. Only shown when at least one campaign is defined.
func _add_campaign_button() -> void:
	if DataLoader.campaigns.is_empty():
		return
	var vbox := single_battle_button.get_parent()
	var btn := Button.new()
	btn.text = "戰役"
	btn.custom_minimum_size = single_battle_button.custom_minimum_size
	btn.add_theme_font_size_override("font_size",
		single_battle_button.get_theme_font_size("font_size"))
	btn.pressed.connect(_on_campaign_pressed)
	vbox.add_child(btn)
	vbox.move_child(btn, single_battle_button.get_index() + 1)

func _add_conquest_button() -> void:
	if DataLoader.conquests.is_empty():
		return
	var vbox := single_battle_button.get_parent()
	var btn := Button.new()
	btn.text = "征服"
	btn.custom_minimum_size = single_battle_button.custom_minimum_size
	btn.add_theme_font_size_override("font_size",
		single_battle_button.get_theme_font_size("font_size"))
	btn.pressed.connect(_on_conquest_pressed)
	vbox.add_child(btn)
	vbox.move_child(btn, quit_button.get_index())

# Global tech tree entry. Only shown when techs are defined. Opens in global
# (no campaign/conquest) context so the screen's "back" returns to this menu.
func _add_tech_button() -> void:
	if DataLoader.techs.is_empty():
		return
	var vbox := single_battle_button.get_parent()
	var btn := Button.new()
	btn.text = "科技研發"
	btn.custom_minimum_size = single_battle_button.custom_minimum_size
	btn.add_theme_font_size_override("font_size",
		single_battle_button.get_theme_font_size("font_size"))
	btn.pressed.connect(_on_tech_pressed)
	vbox.add_child(btn)
	vbox.move_child(btn, quit_button.get_index())

func _on_tech_pressed() -> void:
	GameState.clear_campaign()
	GameState.clear_conquest()
	get_tree().change_scene_to_file("res://scenes/tech_screen.tscn")

func _on_single_battle_pressed() -> void:
	GameState.clear_campaign()
	GameState.clear_conquest()
	GameState.browsing_campaigns = false
	get_tree().change_scene_to_file("res://scenes/scenario_select.tscn")

func _on_campaign_pressed() -> void:
	GameState.clear_conquest()
	GameState.browsing_campaigns = true
	get_tree().change_scene_to_file("res://scenes/scenario_select.tscn")

func _on_conquest_pressed() -> void:
	GameState.clear_campaign()
	# One conquest for now — start it directly and open the strategic map.
	GameState.start_conquest(String(DataLoader.conquests.keys()[0]))
	get_tree().change_scene_to_file("res://scenes/conquest_map.tscn")

func _on_quit_pressed() -> void:
	get_tree().quit()
