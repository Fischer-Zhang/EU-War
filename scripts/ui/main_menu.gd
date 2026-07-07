extends Control

@onready var single_battle_button: Button = $VBox/SingleBattleButton
@onready var quit_button: Button = $VBox/QuitButton

func _ready() -> void:
	single_battle_button.pressed.connect(_on_single_battle_pressed)
	quit_button.pressed.connect(_on_quit_pressed)
	single_battle_button.grab_focus()

func _on_single_battle_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/scenario_select.tscn")

func _on_quit_pressed() -> void:
	get_tree().quit()
