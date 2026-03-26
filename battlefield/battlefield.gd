class_name Battlefield
extends Node3D

const UNIT_NODE_SCENE = preload("res://battlefield/unit_node.tscn")

# Row Z positions (distance from center line)
const ROW_Z = {
	"front": 1.5,
	"middle": 3.5,
	"back": 5.5
}
const ROW_SPACING_X = 1.2

var _unit_registry: Dictionary = {}   # unitId (int) -> UnitNode
var _prev_positions: Dictionary = {}  # unitId (int) -> Vector3
var _visual_hooks: VisualHooks = null
var _camera: Camera3D = null

func set_visual_hooks(hooks: VisualHooks) -> void:
	_visual_hooks = hooks

func set_camera(camera: Camera3D) -> void:
	_camera = camera

func apply_snapshot(prev_snapshot: Variant, current_snapshot: Variant, transition_type: String) -> void:
	# Cache positions BEFORE reconciliation (for death effect positioning)
	_prev_positions.clear()
	for unit_id in _unit_registry:
		_prev_positions[unit_id] = _unit_registry[unit_id].global_position

	# Reconcile nodes to match snapshot
	_reconcile(current_snapshot)

	# Dispatch hooks only on forward transitions
	if transition_type == "forward" and current_snapshot and _visual_hooks:
		var context = _build_visual_context(prev_snapshot, current_snapshot)
		_visual_hooks.dispatch(current_snapshot.get("events", []), context)

func _build_visual_context(prev_snapshot: Variant, current_snapshot: Variant) -> VisualContext:
	var ctx = VisualContext.new()
	ctx.prev_snapshot = prev_snapshot
	ctx.current_snapshot = current_snapshot
	ctx._unit_registry = _unit_registry
	ctx._prev_positions = _prev_positions
	ctx.battlefield_root = self
	ctx.camera = _camera
	return ctx

func _reconcile(snapshot: Variant) -> void:
	if snapshot == null:
		return

	# Build set of ALL current unit IDs with their data, tagged with owner
	var current_units: Dictionary = {}  # unitId -> {data, owner}
	for p in range(snapshot["players"].size()):
		var player = snapshot["players"][p]
		for unit in player["units"]:
			var uid = int(unit["id"])
			current_units[uid] = {"data": unit, "owner": p}

	# Remove units no longer present
	var to_remove: Array = []
	for unit_id in _unit_registry:
		if not current_units.has(unit_id):
			to_remove.append(unit_id)
	for unit_id in to_remove:
		_unit_registry[unit_id].queue_free()
		_unit_registry.erase(unit_id)

	# Group units by (owner, slot) to spread stacked units
	# Key = "owner_slot", Value = array of unit_ids
	var slot_groups: Dictionary = {}
	for unit_id in current_units:
		var info = current_units[unit_id]
		var owner = info["owner"]
		var render = info["data"].get("render", {})
		var slot = int(render.get("slot", 15))
		var key = str(owner) + "_" + str(slot)
		if not slot_groups.has(key):
			slot_groups[key] = []
		slot_groups[key].append(unit_id)

	# Spawn or update units with spread positioning
	for key in slot_groups:
		var group = slot_groups[key]
		var group_size = group.size()
		for idx in range(group_size):
			var unit_id = group[idx]
			var info = current_units[unit_id]
			var unit_data = info["data"]
			var owner = info["owner"]
			var pos = _calculate_position(unit_data, owner, idx, group_size)

			if _unit_registry.has(unit_id):
				var node = _unit_registry[unit_id]
				node.update_state(unit_data)
				node.position = pos
			else:
				var node = UNIT_NODE_SCENE.instantiate() as UnitNode
				add_child(node)
				node.setup(unit_data)
				node.update_state(unit_data)
				node.position = pos
				_unit_registry[unit_id] = node

const UNIT_SPREAD_X = 0.9  # spacing between stacked units within a slot group

func _calculate_position(unit_data: Dictionary, owner: int, index_in_group: int = 0, group_size: int = 1) -> Vector3:
	var render = unit_data.get("render", {})
	var row = str(render.get("row", "middle"))
	var slot = int(render.get("slot", 15))

	var z_offset = ROW_Z.get(row, 3.5)
	# Player 0 (blue) = south (positive Z), Player 1 (red) = north (negative Z)
	if owner == 1:
		z_offset = -z_offset

	# Base X position from slot column
	var slot_in_row = slot % 10
	var base_x = (slot_in_row - 4.5) * ROW_SPACING_X

	# Spread units within the same slot group
	# Center the group around base_x
	var spread_offset = 0.0
	if group_size > 1:
		var total_width = (group_size - 1) * UNIT_SPREAD_X
		spread_offset = -total_width / 2.0 + index_in_group * UNIT_SPREAD_X

	return Vector3(base_x + spread_offset, 0.5, z_offset)

func get_unit_node(unit_id: int) -> UnitNode:
	return _unit_registry.get(unit_id)

func get_prev_position(unit_id: int) -> Vector3:
	return _prev_positions.get(unit_id, Vector3.ZERO)
