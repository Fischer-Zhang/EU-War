extends Control

const DIFFICULTY_HINTS := {
	"easy":   "AI 保守:少前瞻、偶爾走位失誤、不追殺、不撤退。",
	"normal": "平衡:會估算反擊風險、集火與保存部隊,強度中等。",
	"hard":   "全面進取:高攻擊權重、強前瞻、積極保存老兵。",
}

@onready var list: VBoxContainer = $Margin/VBox/ListScroll/List
@onready var back_button: Button = $Margin/VBox/BackButton
@onready var easy_btn: Button = $Margin/VBox/DifficultyRow/EasyButton
@onready var normal_btn: Button = $Margin/VBox/DifficultyRow/NormalButton
@onready var hard_btn: Button = $Margin/VBox/DifficultyRow/HardButton
@onready var diff_hint: Label = $Margin/VBox/DifficultyRow/DifficultyHint

func _ready() -> void:
	back_button.pressed.connect(_on_back_pressed)
	easy_btn.pressed.connect(func(): _set_difficulty("easy"))
	normal_btn.pressed.connect(func(): _set_difficulty("normal"))
	hard_btn.pressed.connect(func(): _set_difficulty("hard"))
	_rebuild_scenario_list()
	_refresh_difficulty_buttons()

func _rebuild_scenario_list() -> void:
	for child in list.get_children():
		child.queue_free()
	for s in DataLoader.scenarios:
		var scenario: Dictionary = s
		var scenario_id := String(scenario.get("id", ""))
		var era := String(scenario.get("era", ""))
		var btn := Button.new()
		btn.text = "%s   [%s]" % [String(scenario.get("title", "(無標題)")), era]
		btn.custom_minimum_size = Vector2(0, 46)
		btn.add_theme_font_size_override("font_size", 18)
		btn.clip_text = true
		btn.pressed.connect(func(): _on_scenario_picked(scenario_id))
		list.add_child(btn)

func _set_difficulty(d: String) -> void:
	GameState.difficulty = d
	_refresh_difficulty_buttons()

func _refresh_difficulty_buttons() -> void:
	var d := GameState.difficulty
	easy_btn.button_pressed = (d == "easy")
	normal_btn.button_pressed = (d == "normal")
	hard_btn.button_pressed = (d == "hard")
	diff_hint.text = DIFFICULTY_HINTS.get(d, "")

func _on_scenario_picked(scenario_id: String) -> void:
	GameState.current_scenario_id = scenario_id
	get_tree().change_scene_to_file("res://scenes/briefing.tscn")

func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
