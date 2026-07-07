extends Control

@onready var single_battle_button: Button = $VBox/SingleBattleButton
@onready var quit_button: Button = $VBox/QuitButton

func _ready() -> void:
	single_battle_button.pressed.connect(_on_single_battle_pressed)
	quit_button.pressed.connect(_on_quit_pressed)
	_add_campaign_button()
	single_battle_button.grab_focus()

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

func _on_single_battle_pressed() -> void:
	GameState.clear_campaign()
	GameState.browsing_campaigns = false
	get_tree().change_scene_to_file("res://scenes/scenario_select.tscn")

func _on_campaign_pressed() -> void:
	GameState.browsing_campaigns = true
	get_tree().change_scene_to_file("res://scenes/scenario_select.tscn")

func _on_quit_pressed() -> void:
	get_tree().quit()
