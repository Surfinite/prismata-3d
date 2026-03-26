class_name UnitNode
extends Node3D

@onready var sprite: Sprite3D = $Sprite3D
@onready var label: Label3D = $Label3D

var unit_id: int = -1
var card_id: String = ""

func setup(unit_data: Dictionary) -> void:
	unit_id = int(unit_data["id"])
	card_id = unit_data["cardId"]
	label.text = unit_data["displayName"]

	# Try to load card sprite
	var sprite_path = "res://assets/card_sprites/%s.png" % card_id
	if ResourceLoader.exists(sprite_path):
		sprite.texture = load(sprite_path)

func update_state(unit_data: Dictionary) -> void:
	var state = unit_data.get("state", {})
	var mode = state.get("mode", "idle")

	# Visual indicators via color modulation
	if mode == "under_construction":
		sprite.modulate = Color(0.5, 0.5, 0.5, 0.7)
	elif state.get("blocking", false):
		sprite.modulate = Color(0.3, 0.5, 1.0)  # blue for blocking
	elif state.get("attacking", false):
		sprite.modulate = Color(1.0, 0.4, 0.3)  # red for attacking
	elif int(state.get("chilled", 0)) > 0:
		sprite.modulate = Color(0.5, 0.7, 1.0)  # light blue for chilled
	else:
		sprite.modulate = Color.WHITE
