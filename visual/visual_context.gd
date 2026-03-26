class_name VisualContext
extends RefCounted

var prev_snapshot: Variant
var current_snapshot: Variant
var camera: Camera3D  # OrbitCamera
var battlefield_root: Node3D

# Internal — set by battlefield
var _unit_registry: Dictionary = {}
var _prev_positions: Dictionary = {}

func get_unit_node(unit_id: int) -> Node3D:
	return _unit_registry.get(unit_id)

func has_unit_node(unit_id: int) -> bool:
	return _unit_registry.has(unit_id)

func get_unit_world_position(unit_id: int) -> Vector3:
	var node = get_unit_node(unit_id)
	if node:
		return node.global_position
	return Vector3.ZERO

func get_prev_unit_world_position(unit_id: int) -> Vector3:
	return _prev_positions.get(unit_id, Vector3.ZERO)

func spawn_effect(effect_scene: PackedScene, pos: Vector3) -> Node3D:
	var effect = effect_scene.instantiate() as Node3D
	battlefield_root.add_child(effect)
	effect.global_position = pos
	return effect
